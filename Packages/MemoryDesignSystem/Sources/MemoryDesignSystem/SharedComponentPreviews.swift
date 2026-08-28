import SwiftUI

public struct MemoryComponentPreviewGallery: View {
    public let matrix: MemoryComponentPreviewMatrix

    public init(matrix: MemoryComponentPreviewMatrix = .current) {
        self.matrix = matrix
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MemorySpacing.large) {
                ForEach(matrix.scenarios) { scenario in
                    VStack(alignment: .leading, spacing: MemorySpacing.small) {
                        Text(scenario.id)
                            .font(MemoryTypeToken.caption.font)
                            .foregroundStyle(MemoryColorToken.textTertiary.color)
                        MemoryComponentPreviewScenarioView(scenario: scenario)
                    }
                    .padding(MemorySpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MemoryColorToken.surfaceWindow.color)
                }
            }
            .padding(MemorySpacing.large)
        }
        .background(MemoryColorToken.surfaceSidebar.color)
    }
}

private struct MemoryComponentPreviewScenarioView: View {
    let scenario: MemoryComponentPreviewScenario

    private var sampleText: String {
        scenario.usesLongLocalizedText
            ? "Erinnerungen aus dem Vordergrundfenster des vorherigen Arbeitstages durchsuchen"
            : "yellow lamp yesterday"
    }

    private var permissionExplanation: String {
        scenario.usesLongLocalizedText
            ? "Diese Berechtigung verbessert den lokal verarbeiteten Textkontext und kann jederzeit in den Systemeinstellungen widerrufen werden."
            : "Improves local text context and can be revoked in System Settings."
    }

    @ViewBuilder
    private var component: some View {
        switch scenario.component {
        case .searchField:
            MemorySearchField(
                text: .constant(sampleText),
                model: MemorySearchFieldModel(
                    text: sampleText,
                    initiallyFocused: scenario.keyboardFocused,
                    state: scenario.interactionState
                )
            )
        case .filterToken:
            FilterToken(
                model: FilterTokenModel(
                    id: "yesterday",
                    label: scenario.usesLongLocalizedText
                        ? "Während des gesamten vorherigen Arbeitstages"
                        : "Yesterday",
                    systemImage: "calendar",
                    isSelected: scenario.interactionState == .selected
                ),
                state: scenario.interactionState
            )
        case .filterTokenBar:
            FilterTokenBar(
                tokens: [
                    FilterTokenModel(id: "time", label: "Yesterday", systemImage: "calendar"),
                    FilterTokenModel(id: "app", label: "Safari", systemImage: "app"),
                    FilterTokenModel(
                        id: "site",
                        label: scenario.usesLongLocalizedText
                            ? "documentation.example.com und alle Unterseiten"
                            : "example.com",
                        systemImage: "globe"
                    ),
                ],
                state: scenario.interactionState
            )
        case .captureStatusBadge:
            CaptureStatusBadge(state: captureStatus)
        case .resultCard:
            MemoryResultCard(model: resultModel, state: scenario.interactionState)
                .frame(maxWidth: 320)
        case .evidenceSnippet:
            EvidenceSnippet(
                model: EvidenceSnippetModel(
                    text: scenario.usesLongLocalizedText
                        ? "Die gelbe Lampe befand sich neben dem großen Fenster im Vordergrundfenster."
                        : "yellow lamp near the window",
                    kind: .visual
                ),
                state: scenario.interactionState
            )
        case .permissionRow:
            PermissionRow(
                title: "Accessibility",
                explanation: permissionExplanation,
                requirement: "Recommended",
                state: permissionState,
                interactionState: scenario.interactionState
            )
        case .emptyState:
            EmptyStateView(
                systemImage: "rectangle.stack",
                title: "No screen memory yet",
                message: scenario.usesLongLocalizedText
                    ? "Ihre Bildschirmerinnerungen erscheinen hier, nachdem die Aufzeichnung des aktiven Vordergrundfensters begonnen hat."
                    : "Your screen memory will appear here after recording begins.",
                actionTitle: "Check Capture Status"
            )
        case .inlineError:
            InlineErrorView(
                message: scenario.usesLongLocalizedText
                    ? "Die Suche konnte nicht abgeschlossen werden; Ihre Suchanfrage und alle sichtbaren Filter wurden beibehalten."
                    : "Search could not finish; your query and filters were preserved.",
                diagnosticCode: "SEARCH-LOCAL-012"
            )
        case .progressStatus:
            ProgressStatusView(
                model: ProgressStatusModel(
                    label: scenario.usesLongLocalizedText
                        ? "Weitere visuelle Übereinstimmungen werden lokal hinzugefügt…"
                        : "Adding visual matches…",
                    elapsedSeconds: 0.301,
                    completedFraction: scenario.interactionState == .loading ? nil : 0.62
                )
            )
        case .destructiveConfirmation:
            DestructiveConfirmationSheet(
                model: DestructiveConfirmationModel(
                    title: "Forget this moment?",
                    removalScope: scenario.usesLongLocalizedText
                        ? "Das ausgewählte Bildschirmbild, der durchsuchbare Text und der lokale Vektor werden entfernt."
                        : "The selected screenshot, searchable text, and local vector will be removed.",
                    consequence: "The underlying short video chunk will be rewritten.",
                    confirmLabel: "Forget Moment"
                ),
                isConfirming: scenario.interactionState == .loading
            )
        }
    }

    var body: some View {
        schemeAdjustedComponent
            .memoryPreviewAccessibility(
                reduceMotion: scenario.reduceMotion,
                increasedContrast: scenario.increasedContrast
            )
    }

    @ViewBuilder
    private var schemeAdjustedComponent: some View {
        switch scenario.colorScheme {
        case .system:
            component
        case .light:
            component.environment(\.colorScheme, .light)
        case .dark:
            component.environment(\.colorScheme, .dark)
        }
    }

    private var captureStatus: CaptureStatusState {
        switch scenario.interactionState {
        case .error: .unavailable
        case .loading: .indexing
        case .disabled: .paused
        default: .recording
        }
    }

    private var permissionState: PermissionState {
        switch scenario.interactionState {
        case .error: .denied
        case .disabled: .unavailable
        case .selected: .granted
        default: .unknown
        }
    }

    private var resultModel: MemoryResultCardModel {
        if scenario.usesLongLocalizedText {
            return MemoryResultCardModel(
                id: MemoryResultCardModel.fixture.id,
                title: "Ausführliche Recherche zur gelben Lampe im Vordergrundfenster",
                timeText: "14:14",
                appName: "Safari",
                host: "documentation.example.com",
                evidence: EvidenceSnippetModel(
                    text: "Die gelbe Lampe befand sich neben dem großen Fenster.",
                    kind: .visual
                ),
                resultPosition: 2,
                resultCount: 8
            )
        }
        return .fixture
    }
}

#Preview("LM-012 shared component matrix") {
    MemoryComponentPreviewGallery()
        .frame(width: 820, height: 760)
}
