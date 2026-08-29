import Foundation

public enum MemoryComponentKind: String, CaseIterable, Codable, Sendable {
    case searchField = "MemorySearchField"
    case filterToken = "FilterToken"
    case filterTokenBar = "FilterTokenBar"
    case captureStatusBadge = "CaptureStatusBadge"
    case resultCard = "MemoryResultCard"
    case evidenceSnippet = "EvidenceSnippet"
    case permissionRow = "PermissionRow"
    case emptyState = "EmptyStateView"
    case inlineError = "InlineErrorView"
    case progressStatus = "ProgressStatusView"
    case destructiveConfirmation = "DestructiveConfirmationSheet"
}

public enum ComponentPreviewVariant: String, CaseIterable, Codable, Sendable {
    case normal
    case hover
    case pressed
    case focused
    case disabled
    case selected
    case loading
    case error
    case light
    case dark
    case increasedContrast
    case longLocalization
    case keyboardFocus

    public static let required: [ComponentPreviewVariant] = allCases
}

public enum MemoryComponentInteractionState: String, Codable, Sendable {
    case normal
    case hover
    case pressed
    case focused
    case disabled
    case selected
    case loading
    case error
}

public struct MemorySearchFieldModel: Equatable, Sendable {
    public let text: String
    public let placeholder: String
    public let isInitiallyFocused: Bool
    public let state: MemoryComponentInteractionState

    public init(
        text: String,
        placeholder: String = "Search your screen memory",
        initiallyFocused: Bool,
        state: MemoryComponentInteractionState = .normal
    ) {
        self.text = text
        self.placeholder = placeholder
        isInitiallyFocused = initiallyFocused
        self.state = state
    }

    public var showsClearButton: Bool {
        !text.isEmpty
    }
}

public enum MemoryComposerRoute: String, CaseIterable, Codable, Sendable {
    case searchMemory
    case askAgent

    public var title: String {
        switch self {
        case .searchMemory: "Search Memory"
        case .askAgent: "Ask Agent"
        }
    }

    public var systemImage: String {
        switch self {
        case .searchMemory: "magnifyingglass"
        case .askAgent: "sparkles"
        }
    }
}

public enum MemoryAgentRouteAvailability: String, Codable, Sendable {
    case unavailable
    case ready
    case permissionDenied
}

public struct MemoryAgentRoutePresentation: Equatable, Sendable {
    public let state: MemoryAgentRouteAvailability
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let systemImage: String

    public init(
        state: MemoryAgentRouteAvailability,
        title: String,
        message: String,
        actionTitle: String?,
        systemImage: String
    ) {
        self.state = state
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.systemImage = systemImage
    }

    public static let unavailable = MemoryAgentRoutePresentation(
        state: .unavailable,
        title: "No agent target is available",
        message: "Connect a supported local client and approve a bounded access policy first.",
        actionTitle: "Manage Agent Access",
        systemImage: "terminal"
    )

    public static let permissionDenied = MemoryAgentRoutePresentation(
        state: .permissionDenied,
        title: "This request is outside the approved scope",
        message:
            "Review the time, application, site, image, result, and expiry limits before asking again.",
        actionTitle: "Review Access",
        systemImage: "lock.shield"
    )

    public static func ready(targetName: String) -> MemoryAgentRoutePresentation {
        let normalizedTarget = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedTarget.isEmpty, "A ready agent route requires a detected target")
        return MemoryAgentRoutePresentation(
            state: .ready,
            title: "Ask \(normalizedTarget) with bounded access",
            message:
                "Only the approved time, application, site, image, result, and expiry scope is shared.",
            actionTitle: "Review and Ask",
            systemImage: "lock.shield"
        )
    }
}

public struct MemoryComposerModel: Equatable, Sendable {
    public let route: MemoryComposerRoute
    public let query: String
    public let placeholder: String
    public let agent: MemoryAgentRoutePresentation

    public init(
        route: MemoryComposerRoute,
        query: String,
        placeholder: String = "Describe what you remember",
        agent: MemoryAgentRoutePresentation = .unavailable
    ) {
        self.route = route
        self.query = query
        self.placeholder = placeholder
        self.agent = agent
    }

    public var accessibilityLabel: String {
        switch route {
        case .searchMemory: "Search Memory composer"
        case .askAgent: "Ask Agent composer, \(agent.title)"
        }
    }
}

public struct ApplicationFilterTileModel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let systemImage: String
    public let isSelected: Bool

    public init(id: String, name: String, systemImage: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.isSelected = isSelected
    }

    public var accessibilityLabel: String {
        "\(name), \(isSelected ? "selected" : "not selected") application filter"
    }
}

public struct FilterTokenModel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let systemImage: String?
    public let isRemovable: Bool
    public let isSelected: Bool

    public init(
        id: String,
        label: String,
        systemImage: String? = nil,
        isRemovable: Bool = true,
        isSelected: Bool = false
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.isRemovable = isRemovable
        self.isSelected = isSelected
    }
}

public struct CaptureStatusPresentation: Equatable, Sendable {
    public let label: String
    public let systemImage: String
    public let accessibilityLabel: String
    public let colorToken: MemoryColorToken
}

public enum CaptureStatusState: String, CaseIterable, Codable, Sendable {
    case recording
    case paused
    case unavailable
    case indexing

    public var presentation: CaptureStatusPresentation {
        switch self {
        case .recording:
            CaptureStatusPresentation(
                label: "Recording",
                systemImage: "record.circle.fill",
                accessibilityLabel: "Capture status: Recording",
                colorToken: .statusRecording
            )
        case .paused:
            CaptureStatusPresentation(
                label: "Paused",
                systemImage: "pause.circle.fill",
                accessibilityLabel: "Capture status: Paused",
                colorToken: .statusPaused
            )
        case .unavailable:
            CaptureStatusPresentation(
                label: "Recording unavailable",
                systemImage: "exclamationmark.triangle.fill",
                accessibilityLabel: "Capture status: Recording unavailable",
                colorToken: .statusPaused
            )
        case .indexing:
            CaptureStatusPresentation(
                label: "Indexing",
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                accessibilityLabel: "Capture status: Indexing",
                colorToken: .accent
            )
        }
    }
}

public enum EvidenceKind: String, CaseIterable, Codable, Sendable {
    case accessibilityText = "text match"
    case opticalCharacterRecognition = "OCR match"
    case title = "title match"
    case visual = "visual match"
    case transcript = "transcript match"
}

public struct EvidenceSnippetModel: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let kind: EvidenceKind
    public let lineLimit: Int

    public init(text: String, kind: EvidenceKind, lineLimit: Int = 2) {
        self.text = text
        self.kind = kind
        self.lineLimit = lineLimit
    }
}

public struct MemoryResultCardModel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let timeText: String
    public let appName: String
    public let host: String?
    public let evidence: EvidenceSnippetModel
    public let resultPosition: Int
    public let resultCount: Int
    public let titleLineLimit: Int
    public let thumbnailSystemImage: String

    public init(
        id: UUID,
        title: String,
        timeText: String,
        appName: String,
        host: String?,
        evidence: EvidenceSnippetModel,
        resultPosition: Int,
        resultCount: Int,
        titleLineLimit: Int = 1,
        thumbnailSystemImage: String = "photo"
    ) {
        self.id = id
        self.title = title
        self.timeText = timeText
        self.appName = appName
        self.host = host
        self.evidence = evidence
        self.resultPosition = resultPosition
        self.resultCount = resultCount
        self.titleLineLimit = titleLineLimit
        self.thumbnailSystemImage = thumbnailSystemImage
    }

    public var accessibilityLabel: String {
        let hostPart = host.map { ", \($0)" } ?? ""
        return
            "\(timeText), \(appName)\(hostPart), \(evidence.kind.rawValue), result \(resultPosition) of \(resultCount)"
    }

    public static let fixture = MemoryResultCardModel(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000212")!,
        title: "Yellow lamp research",
        timeText: "2:14 PM",
        appName: "Safari",
        host: "example.com",
        evidence: EvidenceSnippetModel(text: "yellow lamp near the window", kind: .visual),
        resultPosition: 2,
        resultCount: 8
    )
}

public struct PermissionPresentation: Equatable, Sendable {
    public let label: String
    public let systemImage: String
    public let actionTitle: String?
    public let colorToken: MemoryColorToken
}

public enum PermissionState: String, CaseIterable, Codable, Sendable {
    case unknown
    case granted
    case denied
    case revoked
    case unavailable

    public var presentation: PermissionPresentation {
        switch self {
        case .unknown:
            PermissionPresentation(
                label: "Not checked",
                systemImage: "questionmark.circle",
                actionTitle: "Check Permission",
                colorToken: .textSecondary
            )
        case .granted:
            PermissionPresentation(
                label: "Granted",
                systemImage: "checkmark.circle.fill",
                actionTitle: nil,
                colorToken: .statusSuccess
            )
        case .denied:
            PermissionPresentation(
                label: "Permission required",
                systemImage: "exclamationmark.triangle.fill",
                actionTitle: "Open System Settings",
                colorToken: .statusPaused
            )
        case .revoked:
            PermissionPresentation(
                label: "Permission revoked",
                systemImage: "exclamationmark.triangle.fill",
                actionTitle: "Open System Settings",
                colorToken: .statusPaused
            )
        case .unavailable:
            PermissionPresentation(
                label: "Unavailable",
                systemImage: "xmark.circle.fill",
                actionTitle: "Learn More",
                colorToken: .textSecondary
            )
        }
    }
}

public struct ProgressStatusModel: Equatable, Sendable {
    public static let indicatorDelaySeconds: TimeInterval = 0.300

    public let label: String
    public let elapsedSeconds: TimeInterval
    public let completedFraction: Double?

    public init(label: String, elapsedSeconds: TimeInterval, completedFraction: Double? = nil) {
        self.label = label
        self.elapsedSeconds = elapsedSeconds
        self.completedFraction = completedFraction.map { min(max($0, 0), 1) }
    }

    public var showsIndicator: Bool {
        elapsedSeconds > Self.indicatorDelaySeconds
    }
}

public enum DestructiveConfirmationRole: String, Codable, Sendable {
    case destructive
}

public enum DestructiveConfirmationModelError: Error, Equatable {
    case missingTitle
    case missingRemovalScope
    case missingConsequence
    case missingConfirmLabel
}

public struct DestructiveConfirmationModel: Codable, Equatable, Sendable {
    public let title: String
    public let removalScope: String
    public let consequence: String
    public let confirmLabel: String
    public let cancelLabel: String
    public let cancelIsDefault: Bool
    public let confirmRole: DestructiveConfirmationRole

    public init(
        title: String,
        removalScope: String,
        consequence: String,
        confirmLabel: String,
        cancelLabel: String = "Cancel"
    ) {
        self.title = title
        self.removalScope = removalScope
        self.consequence = consequence
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        cancelIsDefault = true
        confirmRole = .destructive
    }

    public func validated() throws -> DestructiveConfirmationModel {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DestructiveConfirmationModelError.missingTitle
        }
        guard !removalScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DestructiveConfirmationModelError.missingRemovalScope
        }
        guard !consequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DestructiveConfirmationModelError.missingConsequence
        }
        guard !confirmLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DestructiveConfirmationModelError.missingConfirmLabel
        }
        return self
    }
}
