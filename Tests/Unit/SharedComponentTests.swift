import Foundation
import MemoryDesignSystem
import XCTest

final class SharedComponentTests: XCTestCase {
    func testComponentCatalogAndRequiredPreviewVariantsAreComplete() {
        XCTAssertEqual(
            MemoryComponentKind.allCases,
            [
                .searchField,
                .filterToken,
                .filterTokenBar,
                .captureStatusBadge,
                .resultCard,
                .evidenceSnippet,
                .permissionRow,
                .emptyState,
                .inlineError,
                .progressStatus,
                .destructiveConfirmation,
            ]
        )
        XCTAssertEqual(
            ComponentPreviewVariant.required,
            [
                .normal,
                .hover,
                .pressed,
                .focused,
                .disabled,
                .selected,
                .loading,
                .error,
                .light,
                .dark,
                .increasedContrast,
                .longLocalization,
                .keyboardFocus,
            ]
        )

        let matrix = MemoryComponentPreviewMatrix.current
        XCTAssertEqual(
            matrix.scenarios.count,
            MemoryComponentKind.allCases.count * ComponentPreviewVariant.required.count
        )
        XCTAssertEqual(matrix.scenarioCount, matrix.scenarios.count)
        XCTAssertEqual(Set(matrix.scenarios.map(\.id)).count, matrix.scenarios.count)
        for component in MemoryComponentKind.allCases {
            XCTAssertEqual(
                Set(matrix.scenarios.filter { $0.component == component }.map(\.variant)),
                Set(ComponentPreviewVariant.required)
            )
        }
    }

    func testPreviewMatrixPinsAppearanceContrastLocalizationAndKeyboardFocus() {
        let matrix = MemoryComponentPreviewMatrix.current
        let dark = matrix.scenario(component: .resultCard, variant: .dark)
        XCTAssertEqual(dark?.colorScheme, .dark)
        let contrast = matrix.scenario(component: .permissionRow, variant: .increasedContrast)
        XCTAssertTrue(contrast?.increasedContrast == true)
        let localized = matrix.scenario(component: .emptyState, variant: .longLocalization)
        XCTAssertTrue(localized?.usesLongLocalizedText == true)
        let focused = matrix.scenario(component: .searchField, variant: .keyboardFocus)
        XCTAssertTrue(focused?.keyboardFocused == true)
    }

    func testSearchFieldAndProgressBehaviorMatchUXSpecification() {
        XCTAssertTrue(MemorySearchFieldModel(text: "", initiallyFocused: true).isInitiallyFocused)
        XCTAssertFalse(MemorySearchFieldModel(text: "", initiallyFocused: true).showsClearButton)
        XCTAssertTrue(MemorySearchFieldModel(text: "lamp", initiallyFocused: true).showsClearButton)
        XCTAssertFalse(
            ProgressStatusModel(label: "Searching", elapsedSeconds: 0.300).showsIndicator)
        XCTAssertTrue(ProgressStatusModel(label: "Searching", elapsedSeconds: 0.301).showsIndicator)
    }

    func testVisualMemoryComposerRoutesRemainExplicitAndTruthful() {
        XCTAssertEqual(
            MemoryComposerRoute.allCases,
            [.searchMemory, .askAgent]
        )
        XCTAssertEqual(MemoryComposerRoute.searchMemory.title, "Search Memory")
        XCTAssertEqual(MemoryComposerRoute.askAgent.title, "Ask Agent")

        let search = MemoryComposerModel(
            route: .searchMemory,
            query: "yellow lamp"
        )
        XCTAssertEqual(search.accessibilityLabel, "Search Memory composer")

        let unavailable = MemoryComposerModel(
            route: .askAgent,
            query: "yellow lamp",
            agent: .unavailable
        )
        XCTAssertEqual(unavailable.agent.state, .unavailable)
        XCTAssertEqual(unavailable.agent.actionTitle, "Manage Agent Access")
        XCTAssertTrue(unavailable.accessibilityLabel.contains("No agent target is available"))

        let denied = MemoryComposerModel(
            route: .askAgent,
            query: "yellow lamp",
            agent: .permissionDenied
        )
        XCTAssertEqual(denied.agent.state, .permissionDenied)
        XCTAssertTrue(denied.agent.message.contains("time, application, site, image"))

        let ready = MemoryComposerModel(
            route: .askAgent,
            query: "yellow lamp",
            agent: .ready(targetName: "Local Client")
        )
        XCTAssertEqual(ready.agent.state, .ready)
        XCTAssertTrue(ready.agent.title.contains("Local Client"))
        XCTAssertTrue(ready.agent.message.contains("approved"))
    }

    func testApplicationFilterTileAnnouncesSelectionWithoutColor() {
        let selected = ApplicationFilterTileModel(
            id: "com.apple.Safari",
            name: "Safari",
            systemImage: "safari",
            isSelected: true
        )
        let unselected = ApplicationFilterTileModel(
            id: "com.apple.Notes",
            name: "Notes",
            systemImage: "note.text",
            isSelected: false
        )

        XCTAssertEqual(selected.accessibilityLabel, "Safari, selected application filter")
        XCTAssertEqual(unselected.accessibilityLabel, "Notes, not selected application filter")
        XCTAssertNotEqual(selected.systemImage, unselected.systemImage)
    }

    func testCaptureStatusNeverDependsOnColorAlone() {
        for state in CaptureStatusState.allCases {
            let presentation = state.presentation
            XCTAssertFalse(presentation.label.isEmpty)
            XCTAssertFalse(presentation.systemImage.isEmpty)
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
        }
        XCTAssertEqual(Set(CaptureStatusState.allCases.map { $0.presentation.label }).count, 4)
        XCTAssertEqual(
            Set(CaptureStatusState.allCases.map { $0.presentation.systemImage }).count, 4)
    }

    func testResultCardAccessibilityAnnouncesRequiredContextAndPosition() {
        let model = MemoryResultCardModel.fixture
        XCTAssertEqual(model.titleLineLimit, 1)
        XCTAssertEqual(model.evidence.lineLimit, 2)
        XCTAssertEqual(
            model.accessibilityLabel,
            "2:14 PM, Safari, example.com, visual match, result 2 of 8"
        )
    }

    func testPermissionAndDestructiveModelsRemainTruthfulAndSafe() throws {
        XCTAssertEqual(PermissionState.denied.presentation.actionTitle, "Open System Settings")
        XCTAssertEqual(PermissionState.granted.presentation.systemImage, "checkmark.circle.fill")

        let confirmation = try DestructiveConfirmationModel(
            title: "Forget this moment?",
            removalScope: "The selected moment's screenshot, searchable text, and vector",
            consequence: "The underlying short video chunk will be rewritten.",
            confirmLabel: "Forget Moment"
        ).validated()
        XCTAssertTrue(confirmation.cancelIsDefault)
        XCTAssertEqual(confirmation.confirmRole, .destructive)
        XCTAssertThrowsError(
            try DestructiveConfirmationModel(
                title: "Delete?",
                removalScope: "",
                consequence: "Cannot be undone.",
                confirmLabel: "Delete"
            ).validated()
        )
    }

    func testCanonicalComponentMatrixIsCheckedInByteForByte() throws {
        let data = try MemoryComponentPreviewMatrix.canonicalJSON()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let committed = try Data(
            contentsOf: repositoryRoot.appending(path: "Results/LM-012/component-matrix.json")
        )

        XCTAssertEqual(data, committed)
        XCTAssertEqual(
            try JSONDecoder().decode(MemoryComponentPreviewMatrix.self, from: data),
            .current
        )
    }
}
