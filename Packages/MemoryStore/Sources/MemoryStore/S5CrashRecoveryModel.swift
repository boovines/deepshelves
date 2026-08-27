public struct S5CrashRecoveryReport: Codable, Equatable, Sendable {
    public let crashPointCount: Int
    public let consistentRecoveryCount: Int
    public let searchableMissingMediaCount: Int
    public let orphanReadyMediaCount: Int
    public let boundariesExercised: Int
}

public enum S5CrashRecoveryError: Error, Equatable, Sendable {
    case invalidCrashPointCount
    case inconsistentRecovery(Int)
}

public enum S5CrashRecoveryModel: Sendable {
    private struct State {
        var databaseReadyPath = "old.mov"
        var readyFiles: Set<String> = ["old.mov"]
        var partialFiles: Set<String> = []
    }

    public static func verify(crashPointCount: Int) throws -> S5CrashRecoveryReport {
        guard crashPointCount > 0 else {
            throw S5CrashRecoveryError.invalidCrashPointCount
        }

        var consistent = 0
        var missing = 0
        var orphan = 0
        var exercised: Set<Int> = []

        for crashPoint in 0..<crashPointCount {
            let boundary = crashPoint % 10
            exercised.insert(boundary)
            var state = State()
            applyOperations(through: boundary, state: &state)
            recover(state: &state)

            let searchableMissing = state.readyFiles.contains(state.databaseReadyPath) ? 0 : 1
            let orphanReady = state.readyFiles.subtracting([state.databaseReadyPath]).count
            missing += searchableMissing
            orphan += orphanReady
            guard searchableMissing == 0, orphanReady == 0, state.partialFiles.isEmpty else {
                throw S5CrashRecoveryError.inconsistentRecovery(crashPoint)
            }
            consistent += 1
        }

        return S5CrashRecoveryReport(
            crashPointCount: crashPointCount,
            consistentRecoveryCount: consistent,
            searchableMissingMediaCount: missing,
            orphanReadyMediaCount: orphan,
            boundariesExercised: exercised.count
        )
    }

    private static func applyOperations(through boundary: Int, state: inout State) {
        if boundary >= 1 {
            state.partialFiles.insert("candidate.mov.partial")
        }
        if boundary >= 3 {
            state.partialFiles.remove("candidate.mov.partial")
            state.readyFiles.insert("candidate.mov")
        }
        if boundary >= 6 {
            state.databaseReadyPath = "candidate.mov"
        }
        if boundary >= 8 {
            state.readyFiles.remove("old.mov")
        }
    }

    private static func recover(state: inout State) {
        state.partialFiles.removeAll()
        if state.databaseReadyPath == "old.mov" {
            state.readyFiles.remove("candidate.mov")
            state.readyFiles.insert("old.mov")
        } else {
            state.readyFiles.remove("old.mov")
            state.readyFiles.insert("candidate.mov")
        }
    }
}
