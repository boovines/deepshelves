import CoreVideo
import CryptoKit
import Foundation
import MemoryCapture
import MemoryContracts

@main
enum LM025HEICKeyframeHarness {
    static func main() throws {
        if CommandLine.arguments.count == 4,
            CommandLine.arguments[1] == "--termination-child"
        {
            try runTerminationChild(
                outputDirectoryURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                readyURL: URL(fileURLWithPath: CommandLine.arguments[3])
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm025-heic-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let chunkID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let epochID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let output = root.appendingPathComponent(chunkID.uuidString.lowercased(), isDirectory: true)
        let deletionSentinel = "LM025_DELETE_SENTINEL"
        let encoder = DeterministicBoundaryEncoder(payloads: [
            Data("retained-first".utf8),
            Data(deletionSentinel.utf8),
            Data("retained-last".utf8),
        ])
        let writer = try HEICKeyframeWriter(
            outputDirectoryURL: output,
            chunkID: chunkID,
            scope: MediaChunkScope(
                epochID: epochID,
                targetWindowID: 8,
                dimensions: MemoryCapture.PixelSize(width: 1_920, height: 1_080),
                startedNanoseconds: 1_000
            ),
            encoder: encoder
        )
        let source = try makePixelBuffer(width: 3_840, height: 2_160)
        let frameIDs = [
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        ]
        for (frameID, time) in zip(frameIDs, [10_000, 10_400, 11_750]) {
            _ = try writer.append(
                source,
                frameID: frameID,
                captureEpochID: epochID,
                targetWindowID: 8,
                sourcePresentationTimeMilliseconds: Int64(time)
            )
        }

        guard let finalization = try writer.finish() else {
            throw HarnessError.failed("nonempty finalization")
        }
        try require(finalization.frameCount == 3, "frame count")
        try require(finalization.durationMilliseconds == 1_750, "logical duration")
        try require(encoder.destinations.count == 3, "encoder invocation count")
        try require(
            encoder.destinations.allSatisfy {
                $0 == MemoryCapture.PixelSize(width: 1_920, height: 1_080)
            },
            "downscale"
        )
        try require(finalization.manifest.frames.map(\.frameID) == frameIDs, "frame identity")
        try require(
            finalization.manifest.frames.map(\.presentationTimeMS) == [0, 400, 1_750],
            "ordered logical times"
        )
        let manifestURL = output.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        try require(
            finalization.sha256 == Data(SHA256.hash(data: manifestData)),
            "canonical manifest digest"
        )
        for entry in finalization.manifest.frames {
            let assetURL = output.appendingPathComponent(entry.relativePath)
            let bytes = try Data(contentsOf: assetURL)
            try require(Int64(bytes.count) == entry.byteCount, "frame byte count")
            try require(Data(SHA256.hash(data: bytes)) == entry.sha256, "frame digest")
            let attributes = try FileManager.default.attributesOfItem(atPath: assetURL.path)
            try require(attributes[.posixPermissions] as? Int == 0o600, "owner-only frame")
        }
        try require(
            !FileManager.default.fileExists(atPath: writer.stagingDirectoryURL.path),
            "staging hidden after publish"
        )

        let replacementChunkID = UUID(
            uuidString: "22222222-3333-4444-5555-666666666666")!
        let replacementOutput = root.appendingPathComponent(
            replacementChunkID.uuidString.lowercased(),
            isDirectory: true
        )
        let replacement = try HEICKeyframeChunkRewriter.republish(
            sourceDirectoryURL: output,
            outputDirectoryURL: replacementOutput,
            replacementChunkID: replacementChunkID,
            retaining: [frameIDs[0], frameIDs[2]]
        )
        try require(
            replacement.manifest.frames.map(\.frameID) == [frameIDs[0], frameIDs[2]],
            "retained identities"
        )
        try require(
            replacement.manifest.frames.map(\.presentationTimeMS) == [0, 1_750],
            "retained logical timing"
        )
        let replacementBytes = try recursiveBytes(at: replacementOutput)
        try require(
            replacementBytes.range(of: Data(deletionSentinel.utf8)) == nil,
            "deleted sentinel absent"
        )
        try require(
            replacementBytes.range(of: Data(frameIDs[1].uuidString.lowercased().utf8)) == nil,
            "deleted frame identity absent"
        )
        try HEICKeyframeChunkRewriter.removeRetiredDirectory(
            output,
            expectedChunkID: chunkID
        )
        try require(
            !FileManager.default.fileExists(atPath: output.path),
            "retired source removed"
        )

        try verifyAtomicFaultBoundaries(root: root)
        print("LM-025 HEIC keyframe writer tracer: passed")
    }

    private static func verifyAtomicFaultBoundaries(root: URL) throws {
        for fault in [MediaPublishFault.beforeRename, .afterRenameBeforeDirectorySync] {
            let output = root.appendingPathComponent("fault-\(fault.rawValue)", isDirectory: true)
            let writer = try HEICKeyframeWriter(
                outputDirectoryURL: output,
                scope: MediaChunkScope(
                    epochID: UUID(),
                    targetWindowID: 19,
                    dimensions: MemoryCapture.PixelSize(width: 320, height: 180),
                    startedNanoseconds: 0
                ),
                encoder: DeterministicBoundaryEncoder(payloads: [Data("fault-frame".utf8)])
            )
            _ = try writer.append(
                makePixelBuffer(width: 320, height: 180),
                frameID: UUID(),
                captureEpochID: writer.scope.epochID,
                targetWindowID: writer.scope.targetWindowID,
                sourcePresentationTimeMilliseconds: 1_000
            )
            do {
                _ = try writer.finish(fault: fault)
                throw HarnessError.failed("missing injected fault")
            } catch let error as MediaChunkPublisherError {
                try require(error == .injectedFault(fault), "expected publication fault")
            }
            switch fault {
            case .beforeRename:
                try require(
                    FileManager.default.fileExists(atPath: writer.stagingDirectoryURL.path),
                    "pre-rename staging retained for recovery"
                )
                try require(
                    !FileManager.default.fileExists(atPath: output.path),
                    "pre-rename output hidden"
                )
                try FileManager.default.removeItem(at: writer.stagingDirectoryURL)
            case .afterRenameBeforeDirectorySync:
                try require(
                    !FileManager.default.fileExists(atPath: writer.stagingDirectoryURL.path),
                    "post-rename staging consumed"
                )
                try require(
                    FileManager.default.fileExists(atPath: output.path),
                    "post-rename complete directory recoverable"
                )
            }
        }
    }

    private static func runTerminationChild(
        outputDirectoryURL: URL,
        readyURL: URL
    ) throws -> Never {
        let writer = try HEICKeyframeWriter(
            outputDirectoryURL: outputDirectoryURL,
            scope: MediaChunkScope(
                epochID: UUID(),
                targetWindowID: 23,
                dimensions: MemoryCapture.PixelSize(width: 320, height: 180),
                startedNanoseconds: 0
            ),
            encoder: DeterministicBoundaryEncoder(payloads: [Data("termination-frame".utf8)])
        )
        _ = try writer.append(
            makePixelBuffer(width: 320, height: 180),
            frameID: UUID(),
            captureEpochID: writer.scope.epochID,
            targetWindowID: writer.scope.targetWindowID,
            sourcePresentationTimeMilliseconds: 1_000
        )
        try Data("ready".utf8).write(to: readyURL, options: .withoutOverwriting)
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func recursiveBytes(at root: URL) throws -> Data {
        var result = Data()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else {
            return result
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(try Data(contentsOf: item))
            }
        }
        return result
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw HarnessError.failed("pixel buffer allocation")
        }
        return buffer
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else {
            throw HarnessError.failed(label)
        }
    }
}

private final class DeterministicBoundaryEncoder: HEICFrameEncoding, @unchecked Sendable {
    private(set) var destinations: [MemoryCapture.PixelSize] = []
    private var payloads: [Data]

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func encode(
        _ source: CVPixelBuffer,
        destinationDimensions: MemoryCapture.PixelSize
    ) throws -> Data {
        destinations.append(destinationDimensions)
        guard !payloads.isEmpty else {
            throw HarnessError.failed("missing fake HEIC payload")
        }
        return payloads.removeFirst()
    }
}

private enum HarnessError: Error {
    case failed(String)
}
