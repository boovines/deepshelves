import CoreML
import Foundation

public struct MobileCLIPModelDescriptor: Equatable, Sendable {
    public let version: String
    public let embeddingDimension: Int
    public let artifactCount: Int
    public let bundledFootprintBytes: Int
    public let manifestSHA256: String

    public init(verifiedResources: VerifiedModelResources) {
        version = verifiedResources.version
        embeddingDimension = MobileCLIPRuntime.dimension
        artifactCount = verifiedResources.artifactCount
        bundledFootprintBytes = verifiedResources.bundledFootprintBytes
        manifestSHA256 = verifiedResources.manifestSHA256
    }
}

public enum MobileCLIPUnavailableReason: String, Equatable, Sendable {
    case resourcesMissing
    case integrityFailure
    case modelLoadFailure
    case tokenizerFailure
    case inferenceFailure

    public var diagnosticCode: String {
        switch self {
        case .resourcesMissing: "MCLIP-RESOURCES"
        case .integrityFailure: "MCLIP-INTEGRITY"
        case .modelLoadFailure: "MCLIP-MODEL"
        case .tokenizerFailure: "MCLIP-TOKENIZER"
        case .inferenceFailure: "MCLIP-INFERENCE"
        }
    }
}

public enum MobileCLIPAvailability: Equatable, Sendable {
    case notChecked
    case ready(MobileCLIPModelDescriptor)
    case unavailable(reason: MobileCLIPUnavailableReason, diagnosticCode: String)
}

public enum MobileCLIPServiceError: Error, Equatable, Sendable {
    case modelUnavailable(MobileCLIPUnavailableReason)
    case invalidImageInput
}

public protocol MobileCLIPEmbeddingRuntime: Sendable {
    func embed(text: String) async throws -> [Float]
    func embed(raster: ThumbnailRaster) async throws -> [Float]
}

public struct MobileCLIPLoadedRuntime: Sendable {
    public let descriptor: MobileCLIPModelDescriptor
    public let runtime: any MobileCLIPEmbeddingRuntime

    public init(
        descriptor: MobileCLIPModelDescriptor,
        runtime: any MobileCLIPEmbeddingRuntime
    ) {
        self.descriptor = descriptor
        self.runtime = runtime
    }
}

public actor MobileCLIPModelService {
    public typealias Loader = @Sendable () throws -> MobileCLIPLoadedRuntime

    private enum State {
        case notChecked
        case ready(MobileCLIPLoadedRuntime)
        case unavailable(MobileCLIPUnavailableReason)
    }

    private let loader: Loader
    private var state: State = .notChecked

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public static func bundled(computeUnits: MLComputeUnits = .all) -> MobileCLIPModelService {
        MobileCLIPModelService {
            let root = try MobileCLIPRuntime.bundledResourceRoot()
            let verified = try MobileCLIPRuntime.verifyBundledResources(root: root)
            let runtime = try MobileCLIPRuntime(
                imageModelURL: root.appending(path: "mobileclip_s0_image.mlmodelc"),
                textModelURL: root.appending(path: "mobileclip_s0_text.mlmodelc"),
                tokenizerRoot: root,
                computeUnits: computeUnits
            )
            return MobileCLIPLoadedRuntime(
                descriptor: MobileCLIPModelDescriptor(verifiedResources: verified),
                runtime: runtime
            )
        }
    }

    @discardableResult
    public func start() -> MobileCLIPAvailability {
        switch state {
        case .notChecked:
            do {
                let loaded = try loader()
                state = .ready(loaded)
            } catch {
                state = .unavailable(Self.startupReason(for: error))
            }
        case .ready, .unavailable:
            break
        }
        return availability
    }

    public var availability: MobileCLIPAvailability {
        switch state {
        case .notChecked:
            .notChecked
        case .ready(let loaded):
            .ready(loaded.descriptor)
        case .unavailable(let reason):
            .unavailable(reason: reason, diagnosticCode: reason.diagnosticCode)
        }
    }

    public func embed(text: String) async throws -> [Float] {
        let loaded = try readyRuntime()
        do {
            return try await loaded.runtime.embed(text: text)
        } catch is MobileCLIPTokenizerError {
            state = .unavailable(.tokenizerFailure)
            throw MobileCLIPServiceError.modelUnavailable(.tokenizerFailure)
        } catch {
            state = .unavailable(.inferenceFailure)
            throw MobileCLIPServiceError.modelUnavailable(.inferenceFailure)
        }
    }

    public func embed(raster: ThumbnailRaster) async throws -> [Float] {
        let loaded = try readyRuntime()
        do {
            return try await loaded.runtime.embed(raster: raster)
        } catch is MobileCLIPPreprocessingError {
            throw MobileCLIPServiceError.invalidImageInput
        } catch {
            state = .unavailable(.inferenceFailure)
            throw MobileCLIPServiceError.modelUnavailable(.inferenceFailure)
        }
    }

    private func readyRuntime() throws -> MobileCLIPLoadedRuntime {
        if case .notChecked = state {
            _ = start()
        }
        switch state {
        case .ready(let loaded):
            return loaded
        case .unavailable(let reason):
            throw MobileCLIPServiceError.modelUnavailable(reason)
        case .notChecked:
            throw MobileCLIPServiceError.modelUnavailable(.modelLoadFailure)
        }
    }

    private static func startupReason(for error: any Error) -> MobileCLIPUnavailableReason {
        if let runtimeError = error as? MobileCLIPRuntimeError {
            switch runtimeError {
            case .bundledResourcesUnavailable:
                return .resourcesMissing
            case .invalidManifest:
                return .integrityFailure
            case .outputUnavailable, .invalidEmbeddingDimension:
                return .modelLoadFailure
            }
        }
        if error is ModelResourceError {
            return .integrityFailure
        }
        if error is MobileCLIPTokenizerError {
            return .tokenizerFailure
        }
        return .modelLoadFailure
    }
}
