import Foundation
import MemoryCapture

@main
enum LM028SoakHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
            let meanHEICBytesPerFrame = Int64(CommandLine.arguments[2]),
            meanHEICBytesPerFrame > 0
        else {
            throw HarnessError.invalidArguments
        }
        let office = try CaptureSoakModel.run(
            configuration: CaptureSoakConfiguration(
                durationSeconds: 8 * 60 * 60,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 10,
                transitionIntervalSeconds: 5 * 60,
                faultIntervalSeconds: 47 * 60,
                excludedIntervalSeconds: 13 * 60,
                meanHEICBytesPerFrame: meanHEICBytesPerFrame,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )
        let accelerated = try CaptureSoakModel.run(
            configuration: CaptureSoakConfiguration(
                durationSeconds: 72 * 60 * 60,
                inputFramesPerSecond: 2,
                retainedFrameIntervalSeconds: 10,
                transitionIntervalSeconds: 90,
                faultIntervalSeconds: 11 * 60,
                excludedIntervalSeconds: 7 * 60,
                meanHEICBytesPerFrame: meanHEICBytesPerFrame,
                projectedActiveHoursPerDay: 8,
                projectedRetentionDays: 30
            )
        )
        let output = LM028SoakOutput(
            schemaVersion: 1,
            office: office,
            accelerated: accelerated
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw HarnessError.outputAlreadyExists
        }
        try data.write(to: outputURL, options: .atomic)
    }
}

private struct LM028SoakOutput: Encodable {
    let schemaVersion: Int
    let office: CaptureSoakReport
    let accelerated: CaptureSoakReport
}

private enum HarnessError: Error {
    case invalidArguments
    case outputAlreadyExists
}
