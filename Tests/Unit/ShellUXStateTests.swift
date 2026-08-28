import Foundation
import MemoryDesignSystem
import XCTest

final class ShellUXStateTests: XCTestCase {
    func testPlanElevenKeyboardMapIsCompleteAndSafe() {
        XCTAssertEqual(ShellKeyboardCommand.allCases.count, 15)
        XCTAssertEqual(ShellKeyboardCommand.openSearch.shortcut, "⌥Space")
        XCTAssertEqual(ShellKeyboardCommand.focusSearch.shortcut, "⌘F")
        XCTAssertEqual(ShellKeyboardCommand.openSettings.shortcut, "⌘,")
        XCTAssertEqual(ShellKeyboardCommand.forgetMoment.shortcut, "⌘Delete")
        XCTAssertTrue(ShellKeyboardCommand.forgetMoment.requiresConfirmation)
        XCTAssertFalse(ShellKeyboardCommand.openSearch.requiresConfirmation)
        XCTAssertEqual(
            Set(ShellKeyboardCommand.allCases.map(\.shortcut)).count,
            ShellKeyboardCommand.allCases.count
        )
    }

    func testStandardContentStatesFollowQuietProgressAndRecoveryRules() {
        XCTAssertNil(ShellContentState.loading(elapsedMilliseconds: 299).presentation)
        XCTAssertEqual(
            ShellContentState.loading(elapsedMilliseconds: 300).presentation?.title,
            "Loading local memory…"
        )
        XCTAssertEqual(ShellContentState.empty.presentation?.actionTitle, "Check Capture Status")
        XCTAssertEqual(ShellContentState.failure.presentation?.diagnosticCode, "LM-SHELL-500")
        XCTAssertEqual(ShellContentState.failure.presentation?.actionTitle, "Try Again")
    }

    func testPseudoLocalizationExpandsEnglishByAtLeastFortyPercent() {
        let source = "Your screen memory will appear here after recording begins."
        let expanded = ShellLocalizationMode.pseudo.localized(source)
        XCTAssertGreaterThanOrEqual(
            expanded.count,
            Int(ceil(Double(source.count) * 1.4))
        )
        XCTAssertTrue(expanded.hasPrefix("［"))
        XCTAssertTrue(expanded.hasSuffix("］"))
        XCTAssertEqual(ShellLocalizationMode.english.localized(source), source)
    }

    func testNavigationHistorySupportsBackForwardWithoutBranchLeakage() {
        var history = MainNavigationHistory(initial: .default)
        let timeline = MainNavigationSnapshot(
            section: .timeline,
            selectedMomentID: nil,
            inspectorRequested: true
        )
        let activity = MainNavigationSnapshot(
            section: .activity,
            selectedMomentID: nil,
            inspectorRequested: true
        )
        history.record(timeline)
        history.record(activity)
        XCTAssertEqual(history.goBack()?.section, .timeline)
        XCTAssertEqual(history.goBack()?.section, .search)
        XCTAssertEqual(history.goForward()?.section, .timeline)

        history.record(activity)
        XCTAssertNil(history.goForward())
        XCTAssertTrue(history.canGoBack)
    }

    func testAccessibilityTranscriptCoversDestinationsStatesAndResultSemantics() {
        for mode in ShellLocalizationMode.allCases {
            let transcript = ShellAccessibilityCatalog.transcript(localization: mode)
            for required in [
                "Search",
                "Timeline",
                "Activity",
                "Settings",
                "empty",
                "loading",
                "error",
                "time, application, host, evidence type, position",
                "timeline accessibility list",
                "activity accessibility table",
            ] {
                XCTAssertTrue(transcript.localizedCaseInsensitiveContains(required))
            }
        }
    }

    func testIconOnlyControlsHaveNonemptyUniqueTooltips() {
        XCTAssertEqual(ShellAccessibilityCatalog.iconTooltips.count, 3)
        XCTAssertEqual(
            Set(ShellAccessibilityCatalog.iconTooltips.values).count,
            ShellAccessibilityCatalog.iconTooltips.count
        )
        XCTAssertFalse(ShellAccessibilityCatalog.iconTooltips.values.contains { $0.isEmpty })
    }

    func testPlanElevenMinimumTargetAndBodyTextSizesAreLocked() {
        XCTAssertGreaterThanOrEqual(ShellAccessibilityCatalog.minimumPointerTargetPoints, 24)
        XCTAssertGreaterThanOrEqual(ShellAccessibilityCatalog.minimumBodyTextPoints, 11)
    }

    func testClockRelativeDayAndWeekStartUseLocaleAwareFoundationFormatting() {
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        let englishTime = ShellLocaleFormatting.time(hour: 14, minute: 14, locale: english)
        XCTAssertTrue(englishTime.contains("2:14"))
        XCTAssertTrue(englishTime.contains("PM"))
        XCTAssertEqual(ShellLocaleFormatting.time(hour: 14, minute: 14, locale: french), "14:14")
        XCTAssertEqual(ShellLocaleFormatting.relativeDay(dayOffset: 0, locale: english), "today")
        XCTAssertEqual(ShellLocaleFormatting.relativeDay(dayOffset: 0, locale: french), "aujourd’hui")
        XCTAssertNotEqual(
            ShellLocaleFormatting.firstWeekday(locale: english),
            ShellLocaleFormatting.firstWeekday(locale: french)
        )
    }
}
