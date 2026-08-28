import Foundation

public enum GlobalSearchPanelDefaults: Sendable {
    public static let width = LM008UIDefaults.panelWidth
    public static let height = LM008UIDefaults.panelHeight
    public static let minimumWidth = LM008UIDefaults.minimumPanelWidth
    public static let minimumHeight = LM008UIDefaults.minimumPanelHeight
    public static let warmAppearanceBudgetMilliseconds = LM008UIDefaults.warmPanelBudgetMilliseconds
    public static let coldAppearanceBudgetMilliseconds = LM008UIDefaults.coldPanelBudgetMilliseconds
}

public enum GlobalShortcutKey: String, Codable, CaseIterable, Sendable {
    case space
    case k

    public var displayName: String {
        switch self {
        case .space: "Space"
        case .k: "K"
        }
    }
}

public struct GlobalShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let option = Self(rawValue: 1 << 0)
    public static let command = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    fileprivate var displayNames: [String] {
        [
            contains(.control) ? "Control" : nil,
            contains(.option) ? "Option" : nil,
            contains(.command) ? "Command" : nil,
            contains(.shift) ? "Shift" : nil,
        ].compactMap { $0 }
    }
}

public struct GlobalSearchShortcut: Codable, Equatable, Hashable, Sendable {
    public let key: GlobalShortcutKey
    public let modifiers: GlobalShortcutModifiers

    public init(key: GlobalShortcutKey, modifiers: GlobalShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let `default` = Self(key: .space, modifiers: [.option])

    public var displayName: String {
        (modifiers.displayNames + [key.displayName]).joined(separator: "–")
    }
}

public enum GlobalShortcutRegistrationState: Codable, Equatable, Sendable {
    case inactive(shortcut: GlobalSearchShortcut)
    case registered(shortcut: GlobalSearchShortcut)
    case collision(shortcut: GlobalSearchShortcut, diagnosticCode: String)

    public var shortcut: GlobalSearchShortcut {
        switch self {
        case let .inactive(shortcut), let .registered(shortcut), let .collision(shortcut, _):
            shortcut
        }
    }

    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }

    public var statusLabel: String {
        switch self {
        case .inactive: "Not registered"
        case .registered: "Active"
        case .collision: "Shortcut unavailable"
        }
    }

    public var recoveryActionTitle: String? {
        if case .collision = self { return "Choose a Different Shortcut…" }
        return nil
    }

    public var diagnosticCode: String? {
        if case let .collision(_, diagnosticCode) = self { return diagnosticCode }
        return nil
    }

    public func recovering(with shortcut: GlobalSearchShortcut) -> Self {
        .inactive(shortcut: shortcut)
    }
}

public struct SearchPanelRectangle: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SearchPanelDisplayDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public let visibleFrame: SearchPanelRectangle
    public let containsPointer: Bool

    public init(
        identifier: String,
        visibleFrame: SearchPanelRectangle,
        containsPointer: Bool
    ) {
        self.identifier = identifier
        self.visibleFrame = visibleFrame
        self.containsPointer = containsPointer
    }
}

public enum GlobalSearchPanelStateError: Error, Equatable, Sendable {
    case noAvailableDisplay
    case displayBelowMinimumSize
}

public struct GlobalSearchPanelPlacement: Codable, Equatable, Sendable {
    public let displayIdentifier: String
    public let frame: SearchPanelRectangle

    public init(displayIdentifier: String, frame: SearchPanelRectangle) {
        self.displayIdentifier = displayIdentifier
        self.frame = frame
    }

    public static func resolve(
        displays: [SearchPanelDisplayDescriptor],
        rememberedDisplayIdentifier: String?
    ) throws -> Self {
        guard !displays.isEmpty else {
            throw GlobalSearchPanelStateError.noAvailableDisplay
        }
        let selected = rememberedDisplayIdentifier.flatMap { remembered in
            displays.first { $0.identifier == remembered }
        } ?? displays.first(where: \.containsPointer) ?? displays[0]
        guard selected.visibleFrame.width >= Double(GlobalSearchPanelDefaults.minimumWidth),
              selected.visibleFrame.height >= Double(GlobalSearchPanelDefaults.minimumHeight)
        else {
            throw GlobalSearchPanelStateError.displayBelowMinimumSize
        }

        let width = min(Double(GlobalSearchPanelDefaults.width), selected.visibleFrame.width)
        let height = min(Double(GlobalSearchPanelDefaults.height), selected.visibleFrame.height)
        let frame = SearchPanelRectangle(
            x: selected.visibleFrame.x + (selected.visibleFrame.width - width) / 2,
            y: selected.visibleFrame.y + (selected.visibleFrame.height - height) / 2,
            width: width,
            height: height
        )
        return Self(displayIdentifier: selected.identifier, frame: frame)
    }
}

public struct GlobalSearchPanelEscapeResult: Equatable, Sendable {
    public let navigation: MainNavigationSnapshot
    public let shouldClosePanel: Bool
}

public enum GlobalSearchPanelEscapeBehavior: Sendable {
    public static func apply(to navigation: MainNavigationSnapshot) -> GlobalSearchPanelEscapeResult {
        GlobalSearchPanelEscapeResult(navigation: navigation, shouldClosePanel: true)
    }
}

public struct GlobalSearchPanelSnapshot: Codable, Equatable, Sendable {
    public let shortcut: GlobalSearchShortcut
    public let rememberedDisplayIdentifier: String?
    public let registrationState: GlobalShortcutRegistrationState

    public init(
        shortcut: GlobalSearchShortcut,
        rememberedDisplayIdentifier: String?,
        registrationState: GlobalShortcutRegistrationState
    ) {
        self.shortcut = shortcut
        self.rememberedDisplayIdentifier = rememberedDisplayIdentifier
        self.registrationState = registrationState
    }

    public static let `default` = Self(
        shortcut: .default,
        rememberedDisplayIdentifier: nil,
        registrationState: .inactive(shortcut: .default)
    )
}

public actor FileGlobalSearchPanelStateStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> GlobalSearchPanelSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            GlobalSearchPanelSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func save(_ snapshot: GlobalSearchPanelSnapshot) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
