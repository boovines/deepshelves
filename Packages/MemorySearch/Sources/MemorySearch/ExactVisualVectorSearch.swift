import Accelerate
import CryptoKit
import Darwin
import Foundation
import MemoryStore

public enum ExactVisualVectorSearchError: Error, Equatable, Sendable {
    case invalidQuery
    case invalidLimit
    case fileChanged
    case invalidHeader
    case invalidSnapshot
    case mappingFailed
    case conversionFailed(Int)
    case checksumMismatch
}

public struct ExactVisualVectorResult: Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let score: Float

    public init(frameID: UUID, capturedAt: Date, score: Float) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.score = score
    }
}

public struct ExactVisualVectorSearcher: Sendable {
    public let chunkCandidateCount: Int

    public init(chunkCandidateCount: Int = 4_096) {
        self.chunkCandidateCount = max(1, min(chunkCandidateCount, 65_536))
    }

    public func search(
        query: [Float],
        snapshot: ArchiveVectorScanSnapshot,
        limit: Int
    ) async throws -> [ExactVisualVectorResult] {
        try Task.checkCancellation()
        guard limit > 0, limit <= 100 else {
            throw ExactVisualVectorSearchError.invalidLimit
        }
        var queryNormSquared = 0.0
        for value in query {
            guard value.isFinite else { throw ExactVisualVectorSearchError.invalidQuery }
            queryNormSquared += Double(value) * Double(value)
        }
        guard query.count == snapshot.dimension,
            abs(sqrt(queryNormSquared) - 1) <= 0.000_01,
            snapshot.vectorByteCount == snapshot.dimension * 2,
            snapshot.fileByteCount >= Int64(ArchiveVectorStore.headerByteCount)
        else {
            throw ExactVisualVectorSearchError.invalidQuery
        }
        guard !snapshot.candidates.isEmpty else { return [] }

        let descriptor = Darwin.open(snapshot.fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExactVisualVectorSearchError.fileChanged }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            Int64(status.st_size) == snapshot.fileByteCount
        else {
            throw ExactVisualVectorSearchError.fileChanged
        }
        let length = Int(snapshot.fileByteCount)
        guard let mapping = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0),
            mapping != MAP_FAILED
        else {
            throw ExactVisualVectorSearchError.mappingFailed
        }
        defer { munmap(mapping, length) }
        try validateHeader(mapping: mapping, snapshot: snapshot)
        let isSequential = snapshot.candidates.indices.dropFirst().allSatisfy { index in
            snapshot.candidates[index].byteOffset
                == snapshot.candidates[index - 1].byteOffset + Int64(snapshot.vectorByteCount)
        }
        madvise(mapping, length, isSequential ? MADV_SEQUENTIAL : MADV_RANDOM)

        var best: [(ArchiveVectorScanCandidate, Float)] = []
        var start = 0
        while start < snapshot.candidates.count {
            try Task.checkCancellation()
            let end = min(snapshot.candidates.count, start + chunkCandidateCount)
            let candidates = snapshot.candidates[start..<end]
            let rows = candidates.count
            for candidate in candidates {
                guard candidate.byteOffset >= Int64(ArchiveVectorStore.headerByteCount),
                    (candidate.byteOffset - Int64(ArchiveVectorStore.headerByteCount))
                        % Int64(snapshot.vectorByteCount) == 0,
                    candidate.byteOffset + Int64(snapshot.vectorByteCount)
                        <= snapshot.fileByteCount,
                    candidate.norm.isFinite,
                    candidate.norm > 0,
                    abs(candidate.norm - 1) <= 0.005,
                    candidate.contentHash.count == 32
                else {
                    throw ExactVisualVectorSearchError.invalidSnapshot
                }
            }
            let elementCount = rows * snapshot.dimension
            var packedFloat16 = [UInt16](repeating: 0, count: elementCount)
            packedFloat16.withUnsafeMutableBytes { destination in
                var row = 0
                while row < rows {
                    var runEnd = row + 1
                    while runEnd < rows,
                        candidates[candidates.index(candidates.startIndex, offsetBy: runEnd)]
                            .byteOffset
                            == candidates[
                                candidates.index(
                                    candidates.startIndex, offsetBy: runEnd - 1
                                )
                            ].byteOffset + Int64(snapshot.vectorByteCount)
                    {
                        runEnd += 1
                    }
                    let first = candidates[
                        candidates.index(candidates.startIndex, offsetBy: row)
                    ]
                    let runByteCount = (runEnd - row) * snapshot.vectorByteCount
                    destination.baseAddress?.advanced(by: row * snapshot.vectorByteCount)
                        .copyMemory(
                            from: mapping.advanced(by: Int(first.byteOffset)),
                            byteCount: runByteCount
                        )
                    row = runEnd
                }
            }
            var floatValues = [Float](repeating: 0, count: elementCount)
            let conversionError = packedFloat16.withUnsafeMutableBytes { sourceBytes in
                floatValues.withUnsafeMutableBytes { destinationBytes in
                    var source = vImage_Buffer(
                        data: sourceBytes.baseAddress,
                        height: 1,
                        width: vImagePixelCount(elementCount),
                        rowBytes: elementCount * 2
                    )
                    var destination = vImage_Buffer(
                        data: destinationBytes.baseAddress,
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
            }
            guard conversionError == kvImageNoError else {
                throw ExactVisualVectorSearchError.conversionFailed(Int(conversionError))
            }
            var scores = [Float](repeating: 0, count: rows)
            floatValues.withUnsafeBufferPointer { matrix in
                query.withUnsafeBufferPointer { vector in
                    scores.withUnsafeMutableBufferPointer { output in
                        vDSP_mmul(
                            matrix.baseAddress!, 1,
                            vector.baseAddress!, 1,
                            output.baseAddress!, 1,
                            vDSP_Length(rows), 1, vDSP_Length(snapshot.dimension)
                        )
                    }
                }
            }
            for (row, candidate) in candidates.enumerated() {
                let score = scores[row] / Float(candidate.norm)
                guard score.isFinite else { throw ExactVisualVectorSearchError.invalidQuery }
                insert((candidate, score), limit: limit, into: &best)
            }
            start = end
        }
        try Task.checkCancellation()
        for (candidate, _) in best {
            let bytes = Data(
                bytes: mapping.advanced(by: Int(candidate.byteOffset)),
                count: snapshot.vectorByteCount
            )
            guard Data(SHA256.hash(data: bytes)) == candidate.contentHash else {
                throw ExactVisualVectorSearchError.checksumMismatch
            }
        }
        return best.map {
            ExactVisualVectorResult(frameID: $0.0.frameID, capturedAt: $0.0.capturedAt, score: $0.1)
        }
    }

    private func insert(
        _ candidate: (ArchiveVectorScanCandidate, Float),
        limit: Int,
        into best: inout [(ArchiveVectorScanCandidate, Float)]
    ) {
        let index =
            best.firstIndex { existing in
                candidate.1 > existing.1
                    || (candidate.1 == existing.1
                        && (candidate.0.capturedAt > existing.0.capturedAt
                            || (candidate.0.capturedAt == existing.0.capturedAt
                                && candidate.0.frameID.uuidString.lowercased()
                                    < existing.0.frameID.uuidString.lowercased())))
            } ?? best.endIndex
        if index < limit {
            best.insert(candidate, at: index)
            if best.count > limit { best.removeLast() }
        } else if best.count < limit {
            best.append(candidate)
        }
    }

    private func validateHeader(
        mapping: UnsafeMutableRawPointer,
        snapshot: ArchiveVectorScanSnapshot
    ) throws {
        let header = Data(bytes: mapping, count: ArchiveVectorStore.headerByteCount)
        guard String(data: header[0..<8], encoding: .utf8) == ArchiveVectorStore.magic,
            readInteger(UInt32.self, header, 8) == 2,
            readInteger(UInt32.self, header, 12) == UInt32(ArchiveVectorStore.headerByteCount),
            readInteger(UInt32.self, header, 16) == UInt32(snapshot.dimension),
            readInteger(UInt32.self, header, 20) == UInt32(snapshot.vectorByteCount),
            Data(header[24..<56]) == snapshot.modelHash,
            Data(SHA256.hash(data: header[0..<136])) == header[136..<168],
            uuid(header[120..<136]) == snapshot.generation
        else {
            throw ExactVisualVectorSearchError.invalidHeader
        }
    }

    private func readInteger<T: FixedWidthInteger>(
        _ type: T.Type,
        _ data: Data,
        _ offset: Int
    ) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + $0.count))
        }
        return T(littleEndian: value)
    }

    private func uuid(_ data: Data.SubSequence) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
