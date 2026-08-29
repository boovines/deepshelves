import Foundation

public enum LocalMemoryCLIExitCode: Int32, Sendable {
    case success = 0
    case usage = 2
    case policyRequired = 3
    case policyDenied = 4
    case notFound = 5
    case policyInvalid = 6
    case cancelled = 7
    case unavailable = 8
}

public enum LocalMemoryCLIError: Error, Equatable, Sendable {
    case invalidArguments
    case policyRequired
    case policyDenied
    case notFound
    case expired
    case revoked
    case cancelled
    case unavailable
    case integrityFailure
}

public struct LocalMemoryCLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct SignedApplicationCLIRoute: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public static func resolve(
        launcherURL: URL,
        arguments: [String],
        standardApplicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Applications", directoryHint: .isDirectory),
        ],
        isExecutable: (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) throws -> Self {
        let helperCandidate =
            launcherURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "MacOS/Local Memory")
        let installedCandidates = standardApplicationsDirectories.map {
            $0.appending(path: "Local Memory.app/Contents/MacOS/Local Memory")
        }
        guard
            let executableURL = ([helperCandidate] + installedCandidates)
                .first(where: isExecutable)
        else {
            throw LocalMemoryCLIError.unavailable
        }
        return Self(
            executableURL: executableURL,
            arguments: [executableURL.path, "--cli"] + arguments
        )
    }
}

public struct SignedApplicationMCPRoute: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public static func resolve(
        launcherURL: URL,
        standardApplicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Applications", directoryHint: .isDirectory),
        ],
        isExecutable: (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) throws -> Self {
        let helperCandidate =
            launcherURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "MacOS/Local Memory")
        let installedCandidates = standardApplicationsDirectories.map {
            $0.appending(path: "Local Memory.app/Contents/MacOS/Local Memory")
        }
        guard
            let executableURL = ([helperCandidate] + installedCandidates)
                .first(where: isExecutable)
        else {
            throw LocalMemoryCLIError.unavailable
        }
        return Self(
            executableURL: executableURL,
            arguments: [executableURL.path, "--mcp"]
        )
    }
}

public struct CLIStatusProjection: Codable, Equatable, Sendable {
    public let recordingState: String
    public let archiveReadable: Bool
    public let policyCount: Int

    public init(recordingState: String, archiveReadable: Bool, policyCount: Int) {
        self.recordingState = recordingState
        self.archiveReadable = archiveReadable
        self.policyCount = policyCount
    }
}

public struct CLIResultProjection: Codable, Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let application: String
    public let bundleID: String
    public let host: String?
    public let excerpt: String?
    public let evidenceSource: String

    public init(
        frameID: UUID,
        capturedAt: Date,
        application: String,
        bundleID: String,
        host: String?,
        excerpt: String?,
        evidenceSource: String
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.application = application
        self.bundleID = bundleID
        self.host = host
        self.excerpt = excerpt
        self.evidenceSource = evidenceSource
    }
}

public struct CLISearchProjection: Codable, Equatable, Sendable {
    public let results: [CLIResultProjection]
    public let nextCursor: String?

    public init(results: [CLIResultProjection], nextCursor: String?) {
        self.results = results
        self.nextCursor = nextCursor
    }
}

public struct CLITimelineGapProjection: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let reason: String

    public init(startedAt: Date, endedAt: Date, reason: String) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
    }
}

public struct CLITimelineProjection: Codable, Equatable, Sendable {
    public let frames: [CLIResultProjection]
    public let gaps: [CLITimelineGapProjection]

    public init(frames: [CLIResultProjection], gaps: [CLITimelineGapProjection]) {
        self.frames = frames
        self.gaps = gaps
    }
}

public struct CLIMomentProjection: Codable, Equatable, Sendable {
    public let result: CLIResultProjection

    public init(result: CLIResultProjection) { self.result = result }
}

public struct CLIImageResourceProjection: Codable, Equatable, Sendable {
    public let resourceID: String
    public let mediaType: String
    public let byteCount: Int

    public init(resourceID: String, mediaType: String, byteCount: Int) {
        self.resourceID = resourceID
        self.mediaType = mediaType
        self.byteCount = byteCount
    }
}

public struct CLISearchInput: Equatable, Sendable {
    public let query: String
    public let policyID: UUID
    public let limit: Int
    public let cursor: String?
}

public struct CLITimelineInput: Equatable, Sendable {
    public let interval: DateInterval
    public let policyID: UUID
}

public struct CLIMomentInput: Equatable, Sendable {
    public let frameID: UUID
    public let policyID: UUID
}

public struct CLIImageResourceInput: Equatable, Sendable {
    public let resourceID: String
    public let policyID: UUID
}

public struct LocalMemoryCLIBackend: Sendable {
    public let status: @Sendable () async throws -> CLIStatusProjection
    public let search: @Sendable (CLISearchInput) async throws -> CLISearchProjection
    public let timeline: @Sendable (CLITimelineInput) async throws -> CLITimelineProjection
    public let moment: @Sendable (CLIMomentInput) async throws -> CLIMomentProjection
    public let imageResource:
        @Sendable (CLIImageResourceInput) async throws -> CLIImageResourceProjection

    public init(
        status: @escaping @Sendable () async throws -> CLIStatusProjection,
        search: @escaping @Sendable (CLISearchInput) async throws -> CLISearchProjection,
        timeline: @escaping @Sendable (CLITimelineInput) async throws -> CLITimelineProjection,
        moment: @escaping @Sendable (CLIMomentInput) async throws -> CLIMomentProjection,
        imageResource:
            @escaping @Sendable (CLIImageResourceInput) async throws
            -> CLIImageResourceProjection
    ) {
        self.status = status
        self.search = search
        self.timeline = timeline
        self.moment = moment
        self.imageResource = imageResource
    }
}

public enum LocalMemoryCLIExecutor {
    public static func execute(
        arguments: [String],
        backend: LocalMemoryCLIBackend,
        auditSink: AgentAccessAuditSink? = nil
    ) async -> LocalMemoryCLIResult {
        var parsedCommand: CLICommand?
        do {
            let command = try parse(arguments)
            parsedCommand = command
            try Task.checkCancellation()
            let output: Data
            let resultCount: Int
            switch command {
            case .status:
                output = try encode(type: "status", data: await backend.status())
                resultCount = 0
            case .search(let input):
                let projection = try await backend.search(input)
                output = try encode(type: "search", data: projection)
                resultCount = projection.results.count
            case .timeline(let input):
                let projection = try await backend.timeline(input)
                output = try encode(type: "timeline", data: projection)
                resultCount = projection.frames.count
            case .moment(let input):
                output = try encode(type: "moment", data: await backend.moment(input))
                resultCount = 1
            case .imageResource(let input):
                output = try encode(
                    type: "imageResource",
                    data: await backend.imageResource(input)
                )
                resultCount = 1
            }
            try Task.checkCancellation()
            try await auditSink?.record(
                command.auditRecord(outcome: .success, resultCount: resultCount))
            return LocalMemoryCLIResult(
                exitCode: LocalMemoryCLIExitCode.success.rawValue,
                standardOutput: output,
                standardError: Data()
            )
        } catch is CancellationError {
            try? await auditSink?.record(
                parsedCommand?.auditRecord(outcome: .cancelled) ?? .statusFailure(.cancelled))
            return failure(.cancelled)
        } catch let error as LocalMemoryCLIError {
            if let command = parsedCommand {
                try? await auditSink?.record(command.auditRecord(outcome: auditOutcome(error)))
            }
            return failure(error)
        } catch {
            if let command = parsedCommand {
                try? await auditSink?.record(command.auditRecord(outcome: .failure))
            }
            return failure(.unavailable)
        }
    }

    private static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { throw LocalMemoryCLIError.invalidArguments }
        let parsed = try ParsedArguments(Array(arguments.dropFirst()))
        switch command {
        case "status":
            guard parsed.positionals.isEmpty, parsed.values.isEmpty else {
                throw LocalMemoryCLIError.invalidArguments
            }
            return .status
        case "search":
            let policyID = try parsed.requiredPolicyID()
            guard parsed.positionals.count == 1,
                let query = parsed.positionals.first,
                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                parsed.unknownOptions(excluding: ["policy", "limit", "cursor"]).isEmpty
            else {
                throw LocalMemoryCLIError.invalidArguments
            }
            let limit = try parsed.boundedInt("limit", default: 20, range: 1...100)
            return .search(
                CLISearchInput(
                    query: query,
                    policyID: policyID,
                    limit: limit,
                    cursor: parsed.values["cursor"]
                )
            )
        case "timeline":
            let policyID = try parsed.requiredPolicyID()
            guard parsed.positionals.isEmpty,
                parsed.unknownOptions(excluding: ["policy", "from", "to"]).isEmpty,
                let from = parsed.values["from"].flatMap(canonicalDate),
                let to = parsed.values["to"].flatMap(canonicalDate),
                from < to
            else {
                throw LocalMemoryCLIError.invalidArguments
            }
            return .timeline(
                CLITimelineInput(interval: DateInterval(start: from, end: to), policyID: policyID)
            )
        case "get-moment":
            let policyID = try parsed.requiredPolicyID()
            guard parsed.positionals.count == 1,
                parsed.unknownOptions(excluding: ["policy"]).isEmpty,
                let value = parsed.positionals.first,
                let frameID = UUID(uuidString: value)
            else {
                throw LocalMemoryCLIError.invalidArguments
            }
            return .moment(CLIMomentInput(frameID: frameID, policyID: policyID))
        case "image-resource":
            let policyID = try parsed.requiredPolicyID()
            guard parsed.positionals.count == 1,
                parsed.unknownOptions(excluding: ["policy"]).isEmpty,
                let resourceID = parsed.positionals.first,
                !resourceID.isEmpty,
                resourceID.count <= 512,
                !resourceID.contains("/")
            else {
                throw LocalMemoryCLIError.invalidArguments
            }
            return .imageResource(
                CLIImageResourceInput(resourceID: resourceID, policyID: policyID)
            )
        default: throw LocalMemoryCLIError.invalidArguments
        }
    }

    private static func encode<Payload: Encodable>(type: String, data: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
            try container.encode(date.formatted(style))
        }
        var bytes = try encoder.encode(CLIEnvelope(type: type, data: data))
        bytes.append(0x0A)
        return bytes
    }

    private static func failure(_ error: LocalMemoryCLIError) -> LocalMemoryCLIResult {
        let mapping: (LocalMemoryCLIExitCode, String) =
            switch error {
            case .invalidArguments: (.usage, "invalid_arguments")
            case .policyRequired: (.policyRequired, "policy_required")
            case .policyDenied: (.policyDenied, "policy_denied")
            case .notFound: (.notFound, "not_found")
            case .expired: (.policyInvalid, "policy_expired")
            case .revoked: (.policyInvalid, "policy_revoked")
            case .cancelled: (.cancelled, "cancelled")
            case .unavailable: (.unavailable, "unavailable")
            case .integrityFailure: (.unavailable, "integrity_failure")
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(CLIErrorEnvelope(error: mapping.1))) ?? Data()
        data.append(0x0A)
        return LocalMemoryCLIResult(
            exitCode: mapping.0.rawValue,
            standardOutput: Data(),
            standardError: data
        )
    }

    private static func canonicalDate(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func auditOutcome(_ error: LocalMemoryCLIError) -> AgentAccessAuditOutcome {
        switch error {
        case .policyRequired, .policyDenied, .expired, .revoked, .notFound: .denied
        case .cancelled: .cancelled
        case .invalidArguments, .unavailable, .integrityFailure: .failure
        }
    }
}

private enum CLICommand: Sendable {
    case status
    case search(CLISearchInput)
    case timeline(CLITimelineInput)
    case moment(CLIMomentInput)
    case imageResource(CLIImageResourceInput)
}

extension CLICommand {
    fileprivate func auditRecord(
        outcome: AgentAccessAuditOutcome,
        resultCount: Int = 0
    ) -> AgentAccessAuditRecord {
        switch self {
        case .status:
            AgentAccessAuditRecord(
                operation: .status,
                outcome: outcome,
                policyID: nil,
                resultCount: resultCount,
                queryHash: nil
            )
        case .search(let input):
            AgentAccessAuditRecord(
                operation: .search,
                outcome: outcome,
                policyID: input.policyID,
                resultCount: resultCount,
                queryHash: AgentAccessAuditHasher.hash(input.query)
            )
        case .timeline(let input):
            AgentAccessAuditRecord(
                operation: .timeline,
                outcome: outcome,
                policyID: input.policyID,
                resultCount: resultCount,
                queryHash: AgentAccessAuditHasher.hash(
                    "\(input.interval.start.timeIntervalSince1970):\(input.interval.end.timeIntervalSince1970)"
                )
            )
        case .moment(let input):
            AgentAccessAuditRecord(
                operation: .moment,
                outcome: outcome,
                policyID: input.policyID,
                resultCount: resultCount,
                queryHash: AgentAccessAuditHasher.hash(input.frameID.uuidString.lowercased())
            )
        case .imageResource(let input):
            AgentAccessAuditRecord(
                operation: .imageResource,
                outcome: outcome,
                policyID: input.policyID,
                resultCount: resultCount,
                queryHash: AgentAccessAuditHasher.hash(input.resourceID)
            )
        }
    }
}

extension AgentAccessAuditRecord {
    fileprivate static func statusFailure(_ outcome: AgentAccessAuditOutcome) -> Self {
        Self(
            operation: .status,
            outcome: outcome,
            policyID: nil,
            resultCount: 0,
            queryHash: nil
        )
    }
}

private struct ParsedArguments {
    let positionals: [String]
    let values: [String: String]

    init(_ arguments: [String]) throws {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--json" {
                index += 1
                continue
            }
            if value.hasPrefix("--") {
                let name = String(value.dropFirst(2))
                guard !name.isEmpty, values[name] == nil, arguments.indices.contains(index + 1),
                    !arguments[index + 1].hasPrefix("--")
                else {
                    throw LocalMemoryCLIError.invalidArguments
                }
                values[name] = arguments[index + 1]
                index += 2
            } else {
                positionals.append(value)
                index += 1
            }
        }
        self.positionals = positionals
        self.values = values
    }

    func requiredPolicyID() throws -> UUID {
        guard let value = values["policy"] else { throw LocalMemoryCLIError.policyRequired }
        guard let identifier = UUID(uuidString: value) else {
            throw LocalMemoryCLIError.invalidArguments
        }
        return identifier
    }

    func boundedInt(_ name: String, default defaultValue: Int, range: ClosedRange<Int>) throws
        -> Int
    {
        guard let value = values[name] else { return defaultValue }
        guard let parsed = Int(value), range.contains(parsed) else {
            throw LocalMemoryCLIError.invalidArguments
        }
        return parsed
    }

    func unknownOptions(excluding allowed: Set<String>) -> Set<String> {
        Set(values.keys).subtracting(allowed)
    }
}

private struct CLIEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion = 1
    let type: String
    let data: Payload
}

private struct CLIErrorEnvelope: Encodable {
    let schemaVersion = 1
    let error: String
}
