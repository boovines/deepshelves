import Foundation

public protocol RecordingGapPersisting: Sendable {
    func persist(recordingGap: RecordingGap) async throws
}
