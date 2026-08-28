import CryptoKit
import Darwin
import Foundation

public enum SoftwareHEICError: Error, Equatable, Sendable {
    case invalidRaster
    case runtimeUnavailable
    case runtimeIntegrityMismatch
    case runtimeInventoryMismatch
    case processLaunchFailed
    case processTimedOut
    case processFailed(Int32)
    case malformedOutput
}

public struct SoftwareHEICRaster: Equatable, Sendable {
    public static let maximumDimension = 1_920

    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]

    public init(width: Int, height: Int, rgba8: [UInt8]) throws {
        guard width > 0, height > 0,
            width <= Self.maximumDimension, height <= Self.maximumDimension,
            width <= Int.max / height / 4,
            rgba8.count == width * height * 4
        else {
            throw SoftwareHEICError.invalidRaster
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }
}

public struct SoftwareHEICCodec: Sendable {
    public static let productionQuality = 82

    private static let rawMagic = Data("LMRGBA01".utf8)
    private static let expectedInventory: Set<String> = [
        "bin/lm-software-heic",
        "lib/libde265.0.2.1.dylib",
        "lib/libheif.1.23.2.dylib",
        "lib/libx265.217.dylib",
        "licenses/libde265-COPYING",
        "licenses/libheif-COPYING",
        "licenses/x265-COPYING",
    ]

    private let runtimeRoot: URL
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) throws {
        guard timeout > 0,
            let root = Bundle.module.url(
                forResource: "SoftwareHEIC",
                withExtension: nil
            )
        else {
            throw SoftwareHEICError.runtimeUnavailable
        }
        runtimeRoot = root
        self.timeout = timeout
        try verifyRuntime()
    }

    public init(runtimeRoot: URL, timeout: TimeInterval = 15) throws {
        guard timeout > 0 else { throw SoftwareHEICError.runtimeUnavailable }
        self.runtimeRoot = runtimeRoot
        self.timeout = timeout
        try verifyRuntime()
    }

    public func encode(
        _ raster: SoftwareHEICRaster,
        quality: Int = Self.productionQuality
    ) throws -> Data {
        guard (0...100).contains(quality) else {
            throw SoftwareHEICError.invalidRaster
        }
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.rgba", isDirectory: false)
        let output = temporary.appendingPathComponent("output.heic", isDirectory: false)
        try writeOwnerOnly(rawData(for: raster), to: input)
        try run(["encode", input.path, output.path, String(quality)])
        let data = try readRegularOwnerFile(output)
        guard data.count >= 12,
            data.subdata(in: 4..<12) == Data("ftypheic".utf8)
        else {
            throw SoftwareHEICError.malformedOutput
        }
        return data
    }

    public func decode(_ data: Data) throws -> SoftwareHEICRaster {
        guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024 else {
            throw SoftwareHEICError.malformedOutput
        }
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.heic", isDirectory: false)
        let output = temporary.appendingPathComponent("output.rgba", isDirectory: false)
        try writeOwnerOnly(data, to: input)
        try run(["decode", input.path, output.path])
        return try parseRaw(try readRegularOwnerFile(output))
    }

    public func verifyRuntime() throws {
        let root = runtimeRoot.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SoftwareHEICError.runtimeUnavailable
        }
        let manifestURL = root.appendingPathComponent("SHA256SUMS", isDirectory: false)
        guard try isRegularFileWithoutSymlink(manifestURL),
            let text = try? String(contentsOf: manifestURL, encoding: .utf8)
        else {
            throw SoftwareHEICError.runtimeUnavailable
        }

        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                throw SoftwareHEICError.runtimeInventoryMismatch
            }
            let hash = String(fields[0])
            let relativePath = String(fields[1])
            guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                Self.expectedInventory.contains(relativePath),
                seen.insert(relativePath).inserted
            else {
                throw SoftwareHEICError.runtimeInventoryMismatch
            }
            let fileURL = root.appendingPathComponent(relativePath, isDirectory: false)
            guard fileURL.standardizedFileURL.path.hasPrefix(root.path + "/"),
                try isRegularFileWithoutSymlink(fileURL),
                let bytes = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                Data(SHA256.hash(data: bytes)).hexString == hash
            else {
                throw SoftwareHEICError.runtimeIntegrityMismatch
            }
        }
        guard seen == Self.expectedInventory else {
            throw SoftwareHEICError.runtimeInventoryMismatch
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        else {
            throw SoftwareHEICError.runtimeUnavailable
        }
        var actualInventory = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isRegularFile == true {
                actualInventory.insert(String(url.path.dropFirst(root.path.count + 1)))
            } else if values.isDirectory != true {
                throw SoftwareHEICError.runtimeInventoryMismatch
            }
        }
        guard actualInventory == Self.expectedInventory.union(["SHA256SUMS"]) else {
            throw SoftwareHEICError.runtimeInventoryMismatch
        }

        let executable = executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SoftwareHEICError.runtimeUnavailable
        }
    }

    private var executableURL: URL {
        runtimeRoot.appendingPathComponent("bin/lm-software-heic", isDirectory: false)
    }

    private func run(_ arguments: [String]) throws {
        try verifyRuntime()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = runtimeRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
        ]
        do {
            try process.run()
        } catch {
            throw SoftwareHEICError.processLaunchFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw SoftwareHEICError.processTimedOut
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SoftwareHEICError.processFailed(process.terminationStatus)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-heic-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return url
        } catch {
            throw SoftwareHEICError.runtimeUnavailable
        }
    }

    private func rawData(for raster: SoftwareHEICRaster) -> Data {
        var data = Self.rawMagic
        data.appendLittleEndian(UInt32(raster.width))
        data.appendLittleEndian(UInt32(raster.height))
        data.append(contentsOf: raster.rgba8)
        return data
    }

    private func parseRaw(_ data: Data) throws -> SoftwareHEICRaster {
        guard data.count >= 16, data.prefix(8) == Self.rawMagic else {
            throw SoftwareHEICError.malformedOutput
        }
        let width = Int(data.littleEndianUInt32(at: 8))
        let height = Int(data.littleEndianUInt32(at: 12))
        guard width > 0, height > 0,
            width <= SoftwareHEICRaster.maximumDimension,
            height <= SoftwareHEICRaster.maximumDimension,
            width <= Int.max / height / 4,
            data.count == 16 + width * height * 4
        else {
            throw SoftwareHEICError.malformedOutput
        }
        return try SoftwareHEICRaster(
            width: width,
            height: height,
            rgba8: Array(data.dropFirst(16))
        )
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw SoftwareHEICError.runtimeUnavailable
        }
    }

    private func readRegularOwnerFile(_ url: URL) throws -> Data {
        guard try isRegularFileWithoutSymlink(url),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            throw SoftwareHEICError.malformedOutput
        }
        return data
    }

    private func isRegularFileWithoutSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

extension Data {
    fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
