import Foundation

public enum ContractViolation: String, Codable, Sendable {
    case empty
    case outOfRange
    case invalidInterval
    case intervalTooLong
    case absolutePath
    case pathTraversal
    case sensitiveURLComponent
    case unsupportedVersion
    case inconsistent
    case missingRequiredValue
    case duplicateValue
}

public struct ContractValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let field: String
    public let violation: ContractViolation
    public let detail: String

    public init(field: String, violation: ContractViolation, detail: String) {
        self.field = field
        self.violation = violation
        self.detail = detail
    }

    public var description: String {
        "Contract validation failed for \(field): \(violation.rawValue) (\(detail))"
    }
}

public protocol ContractValidatable {
    func validate() throws
}

enum ContractChecks {
    static func require(
        _ condition: @autoclosure () -> Bool,
        field: String,
        violation: ContractViolation,
        detail: String
    ) throws {
        guard condition() else {
            throw ContractValidationError(field: field, violation: violation, detail: detail)
        }
    }

    static func validateInterval(
        _ interval: DateInterval,
        field: String,
        maximumDuration: TimeInterval? = nil
    ) throws {
        try require(
            interval.start < interval.end,
            field: field,
            violation: .invalidInterval,
            detail: "interval must be non-empty and half-open"
        )
        if let maximumDuration {
            try require(
                interval.duration <= maximumDuration,
                field: field,
                violation: .intervalTooLong,
                detail: "duration exceeds \(maximumDuration) seconds"
            )
        }
    }

    static func validateRelativePath(_ path: String, field: String) throws {
        try require(
            !path.isEmpty,
            field: field,
            violation: .empty,
            detail: "relative path is empty"
        )
        try require(
            !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains("\\"),
            field: field,
            violation: .absolutePath,
            detail: "archive paths must use relative POSIX components"
        )
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            field: field,
            violation: .pathTraversal,
            detail: "empty, dot, and parent components are forbidden"
        )
        try require(
            !path.unicodeScalars.contains(where: { $0.value == 0 }),
            field: field,
            violation: .pathTraversal,
            detail: "NUL is forbidden"
        )
    }

    static func requireSchemaVersion(_ version: Int, field: String = "schemaVersion") throws {
        try require(
            version >= BootstrapContract.minimumReadableSchemaVersion
                && version <= BootstrapContract.schemaVersion,
            field: field,
            violation: .unsupportedVersion,
            detail: "contract version must be within the supported readable range"
        )
    }
}
