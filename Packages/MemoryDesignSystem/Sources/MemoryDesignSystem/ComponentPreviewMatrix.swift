import Foundation

public enum MemoryPreviewColorScheme: String, Codable, Sendable {
    case system
    case light
    case dark
}

public struct MemoryComponentPreviewScenario: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let component: MemoryComponentKind
    public let variant: ComponentPreviewVariant
    public let interactionState: MemoryComponentInteractionState
    public let colorScheme: MemoryPreviewColorScheme
    public let increasedContrast: Bool
    public let reduceMotion: Bool
    public let usesLongLocalizedText: Bool
    public let keyboardFocused: Bool

    public init(component: MemoryComponentKind, variant: ComponentPreviewVariant) {
        id = "\(component.rawValue).\(variant.rawValue)"
        self.component = component
        self.variant = variant
        interactionState = switch variant {
        case .hover: .hover
        case .pressed: .pressed
        case .focused, .keyboardFocus: .focused
        case .disabled: .disabled
        case .selected: .selected
        case .loading: .loading
        case .error: .error
        default: .normal
        }
        colorScheme = switch variant {
        case .light: .light
        case .dark: .dark
        default: .system
        }
        increasedContrast = variant == .increasedContrast
        reduceMotion = false
        usesLongLocalizedText = variant == .longLocalization
        keyboardFocused = variant == .focused || variant == .keyboardFocus
    }
}

public struct MemoryComponentPreviewMatrix: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let components: [MemoryComponentKind]
    public let variants: [ComponentPreviewVariant]
    public let scenarioCount: Int

    public var scenarios: [MemoryComponentPreviewScenario] {
        components.flatMap { component in
            variants.map { variant in
                MemoryComponentPreviewScenario(component: component, variant: variant)
            }
        }
    }

    public static let current = MemoryComponentPreviewMatrix(
        schemaVersion: 1,
        components: MemoryComponentKind.allCases,
        variants: ComponentPreviewVariant.required,
        scenarioCount: MemoryComponentKind.allCases.count * ComponentPreviewVariant.required.count
    )

    public func scenario(
        component: MemoryComponentKind,
        variant: ComponentPreviewVariant
    ) -> MemoryComponentPreviewScenario? {
        scenarios.first { $0.component == component && $0.variant == variant }
    }

    public static func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(current)
        data.append(0x0A)
        return data
    }
}
