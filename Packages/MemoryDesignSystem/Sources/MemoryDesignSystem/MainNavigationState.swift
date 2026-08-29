import Foundation

public enum MainWindowDefaults: Sendable {
    public static let defaultWidth = 1_120
    public static let defaultHeight = 760
    public static let minimumWidth = 840
    public static let minimumHeight = 560
    public static let sidebarIdealWidth = 184
    public static let sidebarWidthRange = 168...240
    public static let inspectorIdealWidth = 264
    public static let inspectorWidthRange = 220...360
    public static let inspectorVisibilityThreshold = 900
    public static let settingsWidth = 680
    public static let settingsHeight = 560
    public static let momentSymbolWidth = 28
    public static let previewSymbolSize = 48
    public static let previewMinimumHeight = 180

    public static func showsInspector(width: Double, requested: Bool) -> Bool {
        requested && width >= Double(inspectorVisibilityThreshold)
    }
}

public enum MainNavigationSection: String, CaseIterable, Codable, Sendable {
    case search
    case timeline
    case activity
    case settings

    public var title: String {
        switch self {
        case .search: "Search"
        case .timeline: "Timeline"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .timeline: "clock.arrow.circlepath"
        case .activity: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

public struct MainNavigationSnapshot: Codable, Equatable, Sendable {
    public let section: MainNavigationSection
    public let selectedMomentID: UUID?
    public let inspectorRequested: Bool
    public let timelineDate: Date?

    public init(
        section: MainNavigationSection,
        selectedMomentID: UUID?,
        inspectorRequested: Bool,
        timelineDate: Date? = nil
    ) {
        self.section = section
        self.selectedMomentID = selectedMomentID
        self.inspectorRequested = inspectorRequested
        self.timelineDate = timelineDate
    }

    public static let `default` = MainNavigationSnapshot(
        section: .search,
        selectedMomentID: nil,
        inspectorRequested: true,
        timelineDate: nil
    )
}

public enum MainNavigationStateStoreError: Error, Equatable, Sendable {
    case invalidState
}

public actor FileMainNavigationStateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MainNavigationSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                MainNavigationSnapshot.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw MainNavigationStateStoreError.invalidState
        }
    }

    public func save(_ state: MainNavigationSnapshot) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
