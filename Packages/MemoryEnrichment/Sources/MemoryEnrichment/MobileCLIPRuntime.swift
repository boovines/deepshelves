import Accelerate
import CoreML
import Foundation

public enum MobileCLIPRuntimeError: Error, Equatable, Sendable {
    case bundledResourcesUnavailable
    case invalidManifest
    case outputUnavailable
    case invalidEmbeddingDimension(Int)
}

public struct MobileCLIPPixelBuffer: @unchecked Sendable {
    fileprivate let value: CVPixelBuffer

    public init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

public actor MobileCLIPRuntime {
    public static let dimension = 512
    public static let version = "mobileclip-s0-coreml-3e0a7bf"

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer

    public static func bundledResourceRoot() throws -> URL {
        guard let root = Bundle.module.url(
            forResource: "MobileCLIP-S0",
            withExtension: nil
        ) else {
            throw MobileCLIPRuntimeError.bundledResourcesUnavailable
        }
        return root
    }

    public static func bundled(computeUnits: MLComputeUnits = .all) throws -> MobileCLIPRuntime {
        let root = try bundledResourceRoot()
        return try MobileCLIPRuntime(
            imageModelURL: root.appending(path: "mobileclip_s0_image.mlmodelc"),
            textModelURL: root.appending(path: "mobileclip_s0_text.mlmodelc"),
            tokenizerRoot: root,
            manifestRoot: root,
            computeUnits: computeUnits
        )
    }

    public init(
        imageModelURL: URL,
        textModelURL: URL,
        tokenizerRoot: URL,
        manifestRoot: URL? = nil,
        computeUnits: MLComputeUnits = .all
    ) throws {
        if let manifestRoot {
            let manifestURL = manifestRoot.appending(path: "model-manifest.json")
            let manifest: ModelResourceManifest
            do {
                manifest = try JSONDecoder().decode(
                    ModelResourceManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                throw MobileCLIPRuntimeError.invalidManifest
            }
            guard manifest.version == Self.version else {
                throw MobileCLIPRuntimeError.invalidManifest
            }
            try ModelResourceIntegrity.verify(manifest, root: manifestRoot)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        imageModel = try MLModel(contentsOf: imageModelURL, configuration: configuration)
        textModel = try MLModel(contentsOf: textModelURL, configuration: configuration)
        tokenizer = try CLIPTokenizer(resourcesRoot: tokenizerRoot)
    }

    public func embed(image: MobileCLIPPixelBuffer) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: image.value),
        ])
        return try embedding(from: imageModel.prediction(from: input))
    }

    public func embed(text: String) throws -> [Float] {
        let tokenIDs = tokenizer.encode_full(text: text)
        let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
        for (index, token) in tokenIDs.enumerated() {
            array[index] = NSNumber(value: Int32(token))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["text": array])
        return try embedding(from: textModel.prediction(from: input))
    }

    private func embedding(from output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw MobileCLIPRuntimeError.outputUnavailable
        }
        guard array.count == Self.dimension else {
            throw MobileCLIPRuntimeError.invalidEmbeddingDimension(array.count)
        }
        var values = (0 ..< array.count).map { array[$0].floatValue }
        var normSquared: Float = 0
        vDSP_svesq(values, 1, &normSquared, vDSP_Length(values.count))
        let norm = sqrt(normSquared)
        if norm > 0 {
            var divisor = norm
            let count = values.count
            values.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsdiv(buffer.baseAddress!, 1, &divisor, buffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
        return values
    }
}
