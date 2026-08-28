import CoreVideo
import Foundation
import MemoryCapture
import MemoryEnrichment
import MemorySoftwareHEIC
import XCTest

final class SoftwareHEICCodecTests: XCTestCase {
    func testPinnedRuntimeInventoryIntegrityAndRealHEICRoundTrip() throws {
        let codec = try SoftwareHEICCodec()
        try codec.verifyRuntime()
        let source = try stripedRaster(width: 64, height: 32)
        let encoded = try codec.encode(source)

        XCTAssertEqual(encoded.subdata(in: 4..<12), Data("ftypheic".utf8))
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.width, source.width)
        XCTAssertEqual(decoded.height, source.height)
        XCTAssertLessThan(meanAbsoluteRGBError(source.rgba8, decoded.rgba8), 18)
        XCTAssertTrue(
            stride(from: 3, to: decoded.rgba8.count, by: 4).allSatisfy {
                decoded.rgba8[$0] == 255
            })
    }

    func testThumbnailAdaptersProduce480PixelSRGBRealHEIC() throws {
        let adapter = try SoftwareThumbnailHEICCodec()
        let source = try ThumbnailSourceImage(
            raster: ThumbnailRaster(
                width: 960,
                height: 540,
                rgba8: try stripedRaster(width: 960, height: 540).rgba8,
                colorSpace: .sRGB
            ),
            orientation: .right
        )
        let thumbnail = try ThumbnailRasterizer().render(source)
        XCTAssertEqual(thumbnail.size, .init(width: 270, height: 480))

        let encoded = try adapter.encode(thumbnail)
        let decoded = try adapter.decode(encoded)
        XCTAssertEqual(decoded.raster.size, thumbnail.size)
        XCTAssertEqual(decoded.raster.colorSpace, .sRGB)
        XCTAssertEqual(decoded.orientation, .up)
        XCTAssertLessThan(
            meanAbsoluteRGBError(thumbnail.rgba8, decoded.raster.rgba8),
            20
        )
    }

    func testSoftwareCaptureEncoderConvertsVideoRangeYUVWithoutAppleMediaCodec() throws {
        let pixelBuffer = try makeVideoRangePixelBuffer(width: 64, height: 32)
        let encoder = try SoftwareHEICFrameEncoder()
        let encoded = try encoder.encode(
            pixelBuffer,
            destinationDimensions: MemoryCapture.PixelSize(width: 32, height: 16)
        )
        let decoded = try SoftwareHEICCodec().decode(encoded)

        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 16)
        let rgb = stride(from: 0, to: decoded.rgba8.count, by: 4).flatMap {
            Array(decoded.rgba8[$0..<($0 + 3)])
        }
        XCTAssertTrue(rgb.allSatisfy { (90...110).contains(Int($0)) })
    }

    func testRuntimeTamperAndExtraInventoryFailClosedBeforeProcessLaunch() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent(
            "lib/libheif.1.23.2.dylib",
            isDirectory: false
        )
        var data = try Data(contentsOf: library)
        data[data.startIndex] ^= 0xFF
        try data.write(to: library)
        XCTAssertThrowsError(try SoftwareHEICCodec(runtimeRoot: fixture.root)) { error in
            XCTAssertEqual(error as? SoftwareHEICError, .runtimeIntegrityMismatch)
        }

        try fixture.restore()
        try Data("unexpected".utf8).write(
            to: fixture.root.appendingPathComponent("unexpected.bin")
        )
        XCTAssertThrowsError(try SoftwareHEICCodec(runtimeRoot: fixture.root)) { error in
            XCTAssertEqual(error as? SoftwareHEICError, .runtimeInventoryMismatch)
        }
    }

    func testMalformedInputFailsWithContentFreeTypedError() throws {
        let codec = try SoftwareHEICCodec()
        XCTAssertThrowsError(try codec.decode(Data("not-heic".utf8))) { error in
            guard case .processFailed = error as? SoftwareHEICError else {
                return XCTFail("Expected a content-free process error, got \(error)")
            }
        }
    }
}

private final class RuntimeFixture {
    let source: URL
    let root: URL
    private let container: URL

    init() throws {
        source = repositoryRoot.appendingPathComponent(
            "Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/Resources/SoftwareHEIC",
            isDirectory: true
        )
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LM033-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        root = container.appendingPathComponent("SoftwareHEIC", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: source, to: root)
    }

    func restore() throws {
        try FileManager.default.removeItem(at: root)
        try FileManager.default.copyItem(at: source, to: root)
    }

    func remove() { try? FileManager.default.removeItem(at: container) }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func stripedRaster(width: Int, height: Int) throws -> SoftwareHEICRaster {
    let colors: [[UInt8]] = [
        [230, 40, 30, 255],
        [30, 210, 70, 255],
        [40, 80, 230, 255],
    ]
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for _ in 0..<height {
        for x in 0..<width {
            bytes.append(contentsOf: colors[min(2, x * 3 / width)])
        }
    }
    return try SoftwareHEICRaster(width: width, height: height, rgba8: bytes)
}

private func meanAbsoluteRGBError(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
    precondition(lhs.count == rhs.count)
    var total = 0
    var count = 0
    for offset in stride(from: 0, to: lhs.count, by: 4) {
        for channel in 0..<3 {
            total += abs(Int(lhs[offset + channel]) - Int(rhs[offset + channel]))
            count += 1
        }
    }
    return Double(total) / Double(count)
}

private func makeVideoRangePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw SoftwareHEICError.invalidRaster
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw SoftwareHEICError.invalidRaster
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
    else {
        throw SoftwareHEICError.invalidRaster
    }
    memset(yBase, 102, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
    memset(uvBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
    return buffer
}
