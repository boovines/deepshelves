import Foundation

public enum ShellKeyboardCommand: String, CaseIterable, Sendable {
    case openSearch
    case focusSearch
    case searchSection
    case timelineSection
    case activitySection
    case openSettings
    case back
    case forward
    case quickLook
    case openDetail
    case revisit
    case previousTransition
    case nextTransition
    case forgetMoment
    case escape

    public var shortcut: String {
        switch self {
        case .openSearch: "⌥Space"
        case .focusSearch: "⌘F"
        case .searchSection: "⌘1"
        case .timelineSection: "⌘2"
        case .activitySection: "⌘3"
        case .openSettings: "⌘,"
        case .back: "⌘["
        case .forward: "⌘]"
        case .quickLook: "Space"
        case .openDetail: "Return"
        case .revisit: "⌘Return"
        case .previousTransition: "⌥←"
        case .nextTransition: "⌥→"
        case .forgetMoment: "⌘Delete"
        case .escape: "Escape"
        }
    }

    public var action: String {
        switch self {
        case .openSearch: "Open or close search panel"
        case .focusSearch: "Focus search in the current window"
        case .searchSection: "Open Search"
        case .timelineSection: "Open Timeline"
        case .activitySection: "Open Activity"
        case .openSettings: "Open Settings"
        case .back: "Move back through selection history"
        case .forward: "Move forward through selection history"
        case .quickLook: "Quick Look selected moment"
        case .openDetail: "Open selected moment detail"
        case .revisit: "Revisit the selected source"
        case .previousTransition: "Previous application transition"
        case .nextTransition: "Next application transition"
        case .forgetMoment: "Forget selected moment"
        case .escape: "Close transient UI or move back one level"
        }
    }

    public var requiresConfirmation: Bool { self == .forgetMoment }
}

public struct ShellStatePresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let diagnosticCode: String?

    public init(
        title: String,
        message: String,
        actionTitle: String? = nil,
        diagnosticCode: String? = nil
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.diagnosticCode = diagnosticCode
    }
}

public enum ShellContentState: Equatable, Sendable {
    case ready
    case empty
    case loading(elapsedMilliseconds: Int)
    case failure

    public var presentation: ShellStatePresentation? {
        switch self {
        case .ready:
            nil
        case .empty:
            ShellStatePresentation(
                title: "No moments yet",
                message: "Your screen memory will appear here after recording begins.",
                actionTitle: "Check Capture Status"
            )
        case let .loading(elapsedMilliseconds):
            elapsedMilliseconds < 300
                ? nil
                : ShellStatePresentation(
                    title: "Loading local memory…",
                    message: "Reading the local archive."
                )
        case .failure:
            ShellStatePresentation(
                title: "Local memory could not be loaded",
                message: "Your query and filters are preserved.",
                actionTitle: "Try Again",
                diagnosticCode: "LM-SHELL-500"
            )
        }
    }
}

public enum ShellLocalizationMode: String, CaseIterable, Sendable {
    case english
    case pseudo

    public func localized(_ source: String) -> String {
        guard self == .pseudo else { return source }
        let requiredCount = Int(ceil(Double(source.count) * 1.4))
        let contentCount = max(0, requiredCount - 2)
        let paddingCount = max(0, contentCount - source.count)
        return "［\(source)\(String(repeating: "·", count: paddingCount))］"
    }
}

public struct MainNavigationHistory: Sendable {
    private var entries: [MainNavigationSnapshot]
    private var index: Int

    public init(initial: MainNavigationSnapshot) {
        entries = [initial]
        index = 0
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }

    public mutating func record(_ snapshot: MainNavigationSnapshot) {
        guard entries[index] != snapshot else { return }
        if canGoForward {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(snapshot)
        index = entries.count - 1
    }

    public mutating func goBack() -> MainNavigationSnapshot? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    public mutating func goForward() -> MainNavigationSnapshot? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

public enum ShellAccessibilityCatalog: Sendable {
    public static let minimumPointerTargetPoints = 24.0
    public static let minimumBodyTextPoints = 11.0

    public static let iconTooltips = [
        "main.openSettings": "Open Local Memory Settings",
        "main.toggleInspector": "Show or hide moment details",
        "inspector.dismiss": "Hide inspector",
    ]

    public static func transcript(localization: ShellLocalizationMode) -> String {
        let localizedDestinations = MainNavigationSection.allCases
            .map { localization.localized($0.title) }
            .joined(separator: ", ")
        return """
        VoiceOver smoke: \(localization.rawValue)
        Sidebar destinations: \(localizedDestinations)
        Standard states: empty, loading, error
        Result card announces time, application, host, evidence type, position
        Timeline accessibility list exposes markers and gaps
        Activity accessibility table exposes date, hour, recorded minutes, gap minutes
        Keyboard commands: \(ShellKeyboardCommand.allCases.map { "\($0.shortcut) \($0.action)" }.joined(separator: "; "))
        Focus returns after transient panels and confirmation sheets close
        """
    }
}

public enum ShellLocaleFormatting: Sendable {
    public static func time(hour: Int, minute: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 28,
            hour: hour,
            minute: minute
        ))!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func relativeDay(dayOffset: Int, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        return formatter.localizedString(from: DateComponents(day: dayOffset))
    }

    public static func firstWeekday(locale: Locale) -> Int {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        return calendar.firstWeekday
    }
}
