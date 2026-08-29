import AppKit
import Foundation
import SwiftUI

public struct MemoryColorToken: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let semanticSource: String
    public let use: String

    private init(_ name: String, source: String, use: String) {
        self.name = name
        semanticSource = source
        self.use = use
    }

    public static let surfaceWindow = MemoryColorToken(
        "surface.window",
        source: "windowBackgroundColor",
        use: "Window/root"
    )
    public static let surfaceSidebar = MemoryColorToken(
        "surface.sidebar",
        source: "underPageBackgroundColor",
        use: "Sidebar"
    )
    public static let surfaceControl = MemoryColorToken(
        "surface.control",
        source: "controlBackgroundColor",
        use: "Cards, fields"
    )
    public static let surfaceSelected = MemoryColorToken(
        "surface.selected",
        source: "selectedContentBackgroundColor",
        use: "Selection"
    )
    public static let textPrimary = MemoryColorToken(
        "text.primary",
        source: "labelColor",
        use: "Main labels"
    )
    public static let textSecondary = MemoryColorToken(
        "text.secondary",
        source: "secondaryLabelColor",
        use: "Metadata"
    )
    public static let textTertiary = MemoryColorToken(
        "text.tertiary",
        source: "tertiaryLabelColor",
        use: "Hints"
    )
    public static let borderDefault = MemoryColorToken(
        "border.default",
        source: "separatorColor",
        use: "Hairlines"
    )
    public static let accent = MemoryColorToken(
        "accent",
        source: "systemBlue",
        use: "Focus, active selection, primary action"
    )
    public static let statusRecording = MemoryColorToken(
        "status.recording",
        source: "systemRed",
        use: "Recording dot only"
    )
    public static let statusPaused = MemoryColorToken(
        "status.paused",
        source: "systemOrange",
        use: "Paused state"
    )
    public static let statusSuccess = MemoryColorToken(
        "status.success",
        source: "systemGreen",
        use: "Verified completion"
    )

    public static let catalog: [MemoryColorToken] = [
        .surfaceWindow,
        .surfaceSidebar,
        .surfaceControl,
        .surfaceSelected,
        .textPrimary,
        .textSecondary,
        .textTertiary,
        .borderDefault,
        .accent,
        .statusRecording,
        .statusPaused,
        .statusSuccess,
    ]

    public var usesSystemSemanticSource: Bool {
        Self.catalog.contains(self)
    }

    public var nsColor: NSColor {
        switch self {
        case .surfaceWindow: .windowBackgroundColor
        case .surfaceSidebar: .underPageBackgroundColor
        case .surfaceControl: .controlBackgroundColor
        case .surfaceSelected: .selectedContentBackgroundColor
        case .textPrimary: .labelColor
        case .textSecondary: .secondaryLabelColor
        case .textTertiary: .tertiaryLabelColor
        case .borderDefault: .separatorColor
        case .accent: .systemBlue
        case .statusRecording: .systemRed
        case .statusPaused: .systemOrange
        case .statusSuccess: .systemGreen
        default: .labelColor
        }
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }

    public func color(contrast: MemoryContrastPolicy) -> Color {
        if self == .surfaceSelected {
            return color.opacity(contrast.selectedSurfaceOpacity)
        }
        return color
    }
}

public enum MemorySpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let section: CGFloat = 20
    public static let xLarge: CGFloat = 24
    public static let sectionLarge: CGFloat = 28
    public static let xxLarge: CGFloat = 32
    public static let all: [CGFloat] = [xSmall, small, medium, large, xLarge, xxLarge]
}

public enum MemoryRadius {
    public static let control: CGFloat = 6
    public static let card: CGFloat = 10
    public static let floatingPanel: CGFloat = 14
    public static let groupedCard: CGFloat = 20
    public static let canvas: CGFloat = 22
}

public enum MemoryControlHeight {
    public static let compact: CGFloat = 28
    public static let standard: CGFloat = 32
    public static let searchField: CGFloat = 36
}

public enum MemoryHairline {
    public static func width(displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? 1 / displayScale : 1
    }
}

public struct MemoryTypeToken: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let nativeStyle: String
    public let usesMonospacedDigits: Bool

    private init(_ name: String, nativeStyle: String, monospacedDigits: Bool = false) {
        self.name = name
        self.nativeStyle = nativeStyle
        usesMonospacedDigits = monospacedDigits
    }

    public static let caption = MemoryTypeToken("caption", nativeStyle: "caption")
    public static let footnote = MemoryTypeToken("footnote", nativeStyle: "footnote")
    public static let callout = MemoryTypeToken("callout", nativeStyle: "callout")
    public static let body = MemoryTypeToken("body", nativeStyle: "body")
    public static let headline = MemoryTypeToken("headline", nativeStyle: "headline")
    public static let title2 = MemoryTypeToken("title2", nativeStyle: "title2")
    public static let timecode = MemoryTypeToken(
        "timecode",
        nativeStyle: "caption",
        monospacedDigits: true
    )

    public static let catalog: [MemoryTypeToken] = [
        .caption,
        .footnote,
        .callout,
        .body,
        .headline,
        .title2,
        .timecode,
    ]

    public var font: Font {
        let base: Font =
            switch nativeStyle {
            case "caption": .caption
            case "footnote": .footnote
            case "callout": .callout
            case "headline": .headline
            case "title2": .title2
            default: .body
            }
        return usesMonospacedDigits ? base.monospacedDigit() : base
    }
}

public enum MemoryMotionToken: String, CaseIterable, Codable, Sendable {
    case focusHover
    case selectionLayout
    case panelPresentation

    public var name: String {
        switch self {
        case .focusHover: "motion.focusHover"
        case .selectionLayout: "motion.selectionLayout"
        case .panelPresentation: "motion.panelPresentation"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .focusHover: 0.100
        case .selectionLayout: 0.180
        case .panelPresentation: 0.260
        }
    }
}

public enum MemoryMotionPresentation: String, Codable, Equatable, Sendable {
    case movement
    case opacity
}

public struct MemoryMotionPolicy: Equatable, Sendable {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    public func presentation(for _: MemoryMotionToken) -> MemoryMotionPresentation {
        reduceMotion ? .opacity : .movement
    }

    public func effectiveDuration(for token: MemoryMotionToken) -> TimeInterval {
        token.duration
    }

    public func animation(for token: MemoryMotionToken) -> Animation {
        reduceMotion
            ? .linear(duration: effectiveDuration(for: token))
            : .easeInOut(duration: effectiveDuration(for: token))
    }

    public func transition(for movement: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : movement
    }
}

public struct MemoryContrastPolicy: Equatable, Sendable {
    public let increasedContrast: Bool

    public init(increasedContrast: Bool) {
        self.increasedContrast = increasedContrast
    }

    public var selectedSurfaceOpacity: Double {
        increasedContrast ? 0.28 : 0.16
    }

    public var hairlinePhysicalPixels: CGFloat {
        increasedContrast ? 2 : 1
    }

    public func hairlineWidth(displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? hairlinePhysicalPixels / displayScale : hairlinePhysicalPixels
    }
}

public struct MemoryTokenEnvironment: Equatable, Sendable {
    public let motion: MemoryMotionPolicy
    public let contrast: MemoryContrastPolicy
    public let displayScale: CGFloat

    public init(reduceMotion: Bool, increasedContrast: Bool, displayScale: CGFloat) {
        motion = MemoryMotionPolicy(reduceMotion: reduceMotion)
        contrast = MemoryContrastPolicy(increasedContrast: increasedContrast)
        self.displayScale = displayScale > 0 ? displayScale : 1
    }

    public var hairlineWidth: CGFloat {
        contrast.hairlineWidth(displayScale: displayScale)
    }
}

private struct MemoryReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct MemoryIncreasedContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    fileprivate var memoryReduceMotionOverride: Bool? {
        get { self[MemoryReduceMotionOverrideKey.self] }
        set { self[MemoryReduceMotionOverrideKey.self] = newValue }
    }

    fileprivate var memoryIncreasedContrastOverride: Bool? {
        get { self[MemoryIncreasedContrastOverrideKey.self] }
        set { self[MemoryIncreasedContrastOverrideKey.self] = newValue }
    }
}

extension View {
    public func memoryPreviewAccessibility(
        reduceMotion: Bool? = nil,
        increasedContrast: Bool? = nil
    ) -> some View {
        environment(\.memoryReduceMotionOverride, reduceMotion)
            .environment(\.memoryIncreasedContrastOverride, increasedContrast)
    }
}

public struct MemoryTokenReader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.memoryReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.memoryIncreasedContrastOverride) private var increasedContrastOverride

    private let content: (MemoryTokenEnvironment) -> Content

    public init(@ViewBuilder content: @escaping (MemoryTokenEnvironment) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(
            MemoryTokenEnvironment(
                reduceMotion: reduceMotionOverride ?? reduceMotion,
                increasedContrast: increasedContrastOverride
                    ?? (colorSchemeContrast == .increased),
                displayScale: displayScale
            )
        )
    }
}

public struct MemoryScalarToken: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let points: Double

    public init(name: String, points: Double) {
        self.name = name
        self.points = points
    }
}

public struct MemoryMotionSnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let durationMilliseconds: Int

    public init(token: MemoryMotionToken) {
        name = token.name
        durationMilliseconds = Int(token.duration * 1_000)
    }
}

public struct MemoryAccessibilityTokenSnapshot: Codable, Equatable, Sendable {
    public let reduceMotion: String
    public let increasedContrast: String
    public let selectedSurfaceOpacityStandard: Double
    public let selectedSurfaceOpacityIncreased: Double
    public let hairlinePhysicalPixelsStandard: Int
    public let hairlinePhysicalPixelsIncreased: Int
}

public struct MemoryDesignTokenSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let colors: [MemoryColorToken]
    public let spacing: [MemoryScalarToken]
    public let radii: [MemoryScalarToken]
    public let controlHeights: [MemoryScalarToken]
    public let typography: [MemoryTypeToken]
    public let motion: [MemoryMotionSnapshot]
    public let accessibility: MemoryAccessibilityTokenSnapshot
    public let shadows: String
    public let gradientsAllowed: Bool

    public static let current = MemoryDesignTokenSnapshot(
        schemaVersion: 1,
        colors: MemoryColorToken.catalog,
        spacing: zip(
            [
                "spacing.xSmall", "spacing.small", "spacing.medium", "spacing.large",
                "spacing.xLarge", "spacing.xxLarge",
            ],
            MemorySpacing.all
        ).map { MemoryScalarToken(name: $0.0, points: Double($0.1)) },
        radii: [
            MemoryScalarToken(name: "radius.control", points: Double(MemoryRadius.control)),
            MemoryScalarToken(name: "radius.card", points: Double(MemoryRadius.card)),
            MemoryScalarToken(
                name: "radius.floatingPanel", points: Double(MemoryRadius.floatingPanel)),
        ],
        controlHeights: [
            MemoryScalarToken(
                name: "controlHeight.compact", points: Double(MemoryControlHeight.compact)),
            MemoryScalarToken(
                name: "controlHeight.standard", points: Double(MemoryControlHeight.standard)),
            MemoryScalarToken(
                name: "controlHeight.searchField", points: Double(MemoryControlHeight.searchField)),
        ],
        typography: MemoryTypeToken.catalog,
        motion: MemoryMotionToken.allCases.map(MemoryMotionSnapshot.init),
        accessibility: MemoryAccessibilityTokenSnapshot(
            reduceMotion: "replace movement with opacity",
            increasedContrast:
                "strengthen selected surfaces and hairlines while retaining semantic system colors",
            selectedSurfaceOpacityStandard: 0.16,
            selectedSurfaceOpacityIncreased: 0.28,
            hairlinePhysicalPixelsStandard: 1,
            hairlinePhysicalPixelsIncreased: 2
        ),
        shadows: "system window shadow only; cards use semantic borders and surface contrast",
        gradientsAllowed: false
    )

    public static func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(current)
        data.append(0x0A)
        return data
    }
}
