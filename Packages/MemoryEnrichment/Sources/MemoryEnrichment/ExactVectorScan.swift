import Accelerate
import Darwin
import Foundation

public struct VectorSearchResult: Codable, Equatable, Sendable {
    public let index: Int
    public let score: Float

    public init(index: Int, score: Float) {
        self.index = index
        self.score = score
    }
}

public struct ExactVectorFileHeader: Codable, Equatable, Sendable {
    public static let byteCount = 128
    public static let magic = "DSVEC001"

    public let dimension: Int
    public let vectorCount: Int
    public let modelVersion: String
}

public enum ExactVectorError: Error, Equatable, Sendable {
    case emptyVectors
    case invalidDimension
    case invalidHeader
    case truncatedPayload
    case queryDimensionMismatch
    case invalidRange
    case conversionFailed(Int)
    case fileOpenFailed
    case mappingFailed
}

public enum ExactVectorFileWriter {
    public static func write(
        vectors: [[Float]],
        modelVersion: String,
        to url: URL
    ) throws {
        guard let dimension = vectors.first?.count, !vectors.isEmpty else {
            throw ExactVectorError.emptyVectors
        }
        guard dimension > 0, vectors.allSatisfy({ $0.count == dimension }) else {
            throw ExactVectorError.invalidDimension
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: headerData(
            dimension: dimension,
            vectorCount: vectors.count,
            modelVersion: modelVersion
        ))
        var values: [Float] = []
        values.reserveCapacity(dimension * min(vectors.count, 1_024))
        for vector in vectors {
            values.append(contentsOf: vector)
            if values.count >= dimension * 1_024 {
                try write(values, to: handle)
                values.removeAll(keepingCapacity: true)
            }
        }
        if !values.isEmpty {
            try write(values, to: handle)
        }
        try handle.synchronize()
    }

    public static func headerData(
        dimension: Int,
        vectorCount: Int,
        modelVersion: String
    ) -> Data {
        var data = Data(repeating: 0, count: ExactVectorFileHeader.byteCount)
        data.replaceSubrange(0 ..< 8, with: Data(ExactVectorFileHeader.magic.utf8))
        writeInteger(UInt32(1), at: 8, into: &data)
        writeInteger(UInt32(dimension), at: 12, into: &data)
        writeInteger(UInt64(vectorCount), at: 16, into: &data)
        let versionBytes = Data(modelVersion.utf8.prefix(64))
        data.replaceSubrange(24 ..< 24 + versionBytes.count, with: versionBytes)
        return data
    }

    private static func write(_ values: [Float], to handle: FileHandle) throws {
        try handle.write(contentsOf: try encodeFloat16(values))
    }

    private static func writeInteger<Integer: FixedWidthInteger>(
        _ value: Integer,
        at offset: Int,
        into data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
    }
}

public enum ExactVectorBenchmarkCorpus {
    public static func write(
        vectorCount: Int,
        dimension: Int,
        prototypeCount: Int = 64,
        modelVersion: String,
        to url: URL
    ) throws -> [[Float]] {
        guard vectorCount > 0, dimension > 0, prototypeCount > 0 else {
            throw ExactVectorError.invalidDimension
        }
        let prototypes = (0 ..< prototypeCount).map { prototypeIndex in
            normalizedPrototype(index: prototypeIndex, dimension: dimension)
        }
        let vectorsPerBlock = 1_024
        var block: [Float] = []
        block.reserveCapacity(vectorsPerBlock * dimension)
        for vectorIndex in 0 ..< vectorsPerBlock {
            block.append(contentsOf: prototypes[vectorIndex % prototypes.count])
        }
        let blockData = try encodeFloat16(block)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: ExactVectorFileWriter.headerData(
            dimension: dimension,
            vectorCount: vectorCount,
            modelVersion: modelVersion
        ))
        var written = 0
        while vectorCount - written >= vectorsPerBlock {
            try handle.write(contentsOf: blockData)
            written += vectorsPerBlock
        }
        if written < vectorCount {
            let remainderBytes = (vectorCount - written) * dimension * MemoryLayout<UInt16>.size
            try handle.write(contentsOf: blockData.prefix(remainderBytes))
        }
        try handle.synchronize()
        return prototypes
    }

    private static func normalizedPrototype(index: Int, dimension: Int) -> [Float] {
        var state = UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15
        var vector = [Float](repeating: 0, count: dimension)
        for component in 0 ..< dimension {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
            vector[component] = unit * 2 - 1
        }
        var normSquared: Float = 0
        vDSP_svesq(vector, 1, &normSquared, vDSP_Length(dimension))
        var norm = sqrt(normSquared)
        vDSP_vsdiv(vector, 1, &norm, &vector, 1, vDSP_Length(dimension))
        return vector
    }
}

public final class ExactVectorScanner: @unchecked Sendable {
    public let header: ExactVectorFileHeader
    private let fileDescriptor: Int32
    private let chunkVectorCount: Int

    public init(url: URL, chunkVectorCount: Int = 16_384) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExactVectorError.fileOpenFailed }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            Darwin.close(descriptor)
            throw ExactVectorError.fileOpenFailed
        }
        var headerBytes = Data(repeating: 0, count: ExactVectorFileHeader.byteCount)
        let bytesRead = headerBytes.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard bytesRead == ExactVectorFileHeader.byteCount,
              String(data: headerBytes[0 ..< 8], encoding: .utf8) == ExactVectorFileHeader.magic,
              readInteger(UInt32.self, from: headerBytes, at: 8) == 1,
              let dimension = readInteger(UInt32.self, from: headerBytes, at: 12),
              let count = readInteger(UInt64.self, from: headerBytes, at: 16),
              dimension > 0,
              count <= UInt64(Int.max)
        else {
            Darwin.close(descriptor)
            throw ExactVectorError.invalidHeader
        }
        let expectedBytes = ExactVectorFileHeader.byteCount
            + Int(count) * Int(dimension) * MemoryLayout<UInt16>.size
        guard fileStatus.st_size == expectedBytes else {
            Darwin.close(descriptor)
            throw ExactVectorError.truncatedPayload
        }
        let versionData = headerBytes[24 ..< 88]
        let version = String(
            bytes: versionData.prefix(while: { $0 != 0 }),
            encoding: .utf8
        ) ?? ""
        header = ExactVectorFileHeader(
            dimension: Int(dimension),
            vectorCount: Int(count),
            modelVersion: version
        )
        fileDescriptor = descriptor
        self.chunkVectorCount = max(1, chunkVectorCount)
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    public func search(
        query: [Float],
        range: Range<Int>,
        limit: Int
    ) throws -> [VectorSearchResult] {
        guard query.count == header.dimension else {
            throw ExactVectorError.queryDimensionMismatch
        }
        guard range.lowerBound >= 0, range.upperBound <= header.vectorCount,
              range.lowerBound <= range.upperBound
        else {
            throw ExactVectorError.invalidRange
        }
        guard limit > 0, !range.isEmpty else { return [] }

        var best: [VectorSearchResult] = []
        var chunkStart = range.lowerBound
        while chunkStart < range.upperBound {
            let rows = min(chunkVectorCount, range.upperBound - chunkStart)
            let elementCount = rows * header.dimension
            var floatValues = [Float](repeating: 0, count: elementCount)
            let sourceOffset = ExactVectorFileHeader.byteCount
                + chunkStart * header.dimension * MemoryLayout<UInt16>.size
            let sourceByteCount = elementCount * MemoryLayout<UInt16>.size
            let pageSize = Int(getpagesize())
            let mappedOffset = (sourceOffset / pageSize) * pageSize
            let sourceDelta = sourceOffset - mappedOffset
            let mappedLength = sourceDelta + sourceByteCount
            guard let mapping = mmap(
                nil,
                mappedLength,
                PROT_READ,
                MAP_PRIVATE,
                fileDescriptor,
                off_t(mappedOffset)
            ), mapping != MAP_FAILED else {
                throw ExactVectorError.mappingFailed
            }
            madvise(mapping, mappedLength, MADV_SEQUENTIAL)
            let sourcePointer = mapping.advanced(by: sourceDelta)
            let conversionError: vImage_Error = floatValues.withUnsafeMutableBytes { outputBytes in
                var source = vImage_Buffer(
                    data: sourcePointer,
                    height: 1,
                    width: vImagePixelCount(elementCount),
                    rowBytes: sourceByteCount
                )
                var destination = vImage_Buffer(
                    data: outputBytes.baseAddress,
                    height: 1,
                    width: vImagePixelCount(elementCount),
                    rowBytes: elementCount * MemoryLayout<Float>.size
                )
                return vImageConvert_Planar16FtoPlanarF(
                    &source,
                    &destination,
                    vImage_Flags(kvImageNoFlags)
                )
            }
            madvise(mapping, mappedLength, MADV_DONTNEED)
            munmap(mapping, mappedLength)
            guard conversionError == kvImageNoError else {
                throw ExactVectorError.conversionFailed(Int(conversionError))
            }

            var scores = [Float](repeating: 0, count: rows)
            floatValues.withUnsafeBufferPointer { matrix in
                query.withUnsafeBufferPointer { vector in
                    scores.withUnsafeMutableBufferPointer { result in
                        vDSP_mmul(
                            matrix.baseAddress!,
                            1,
                            vector.baseAddress!,
                            1,
                            result.baseAddress!,
                            1,
                            vDSP_Length(rows),
                            1,
                            vDSP_Length(header.dimension)
                        )
                    }
                }
            }
            for row in 0 ..< rows {
                insert(
                    VectorSearchResult(index: chunkStart + row, score: scores[row]),
                    limit: limit,
                    into: &best
                )
            }
            chunkStart += rows
        }
        return best
    }

    private func insert(
        _ candidate: VectorSearchResult,
        limit: Int,
        into values: inout [VectorSearchResult]
    ) {
        let index = values.firstIndex { existing in
            candidate.score > existing.score
                || (candidate.score == existing.score && candidate.index < existing.index)
        } ?? values.endIndex
        if index < limit {
            values.insert(candidate, at: index)
            if values.count > limit { values.removeLast() }
        } else if values.count < limit {
            values.append(candidate)
        }
    }
}

private func readInteger<Integer: FixedWidthInteger>(
    _ type: Integer.Type,
    from data: Data,
    at offset: Int
) -> Integer? {
    guard offset >= 0, offset + MemoryLayout<Integer>.size <= data.count else { return nil }
    var value: Integer = 0
    _ = withUnsafeMutableBytes(of: &value) { destination in
        data.copyBytes(to: destination, from: offset ..< offset + destination.count)
    }
    return Integer(littleEndian: value)
}

private func encodeFloat16(_ values: [Float]) throws -> Data {
    var output = [UInt16](repeating: 0, count: values.count)
    let error = values.withUnsafeBytes { sourceBytes in
        output.withUnsafeMutableBytes { outputBytes in
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                height: 1,
                width: vImagePixelCount(values.count),
                rowBytes: values.count * MemoryLayout<Float>.size
            )
            var destination = vImage_Buffer(
                data: outputBytes.baseAddress,
                height: 1,
                width: vImagePixelCount(values.count),
                rowBytes: values.count * MemoryLayout<UInt16>.size
            )
            return vImageConvert_PlanarFtoPlanar16F(
                &source,
                &destination,
                vImage_Flags(kvImageNoFlags)
            )
        }
    }
    guard error == kvImageNoError else {
        throw ExactVectorError.conversionFailed(Int(error))
    }
    return output.withUnsafeBytes { Data($0) }
}
