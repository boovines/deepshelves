import AppKit
import Foundation
import MemoryCapture
import MemoryContracts
import MemoryDesignSystem
import MemoryStore
import SwiftUI

@MainActor
final class AppLifecycleViewModel: ObservableObject {
    @Published private(set) var snapshot: AppLifecycleSnapshot
    @Published private(set) var captureSnapshot: CaptureLifecycleSnapshot?

    private let lifecycle: LocalMemoryAppLifecycle
    private let captureCoordinator: CaptureLifecycleCoordinator
    private let initialStatus: LocalMemoryRuntimeStatus
    private var startupTask: Task<AppLifecycleSnapshot, Error>?
    private var latestCaptureInputs: CaptureLifecycleInputs?

    init(
        stateURL: URL,
        initialStatus: LocalMemoryRuntimeStatus,
        gapSink: (any RecordingGapPersisting)? = nil
    ) {
        lifecycle = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        captureCoordinator = CaptureLifecycleCoordinator(gapSink: gapSink)
        self.initialStatus = initialStatus
        snapshot = AppLifecycleSnapshot(
            status: initialStatus,
            launchCount: 0,
            mainWindowVisible: false,
            recoveryReason: nil
        )
        Task { [weak self] in
            await self?.start()
        }
    }

    var menuProjection: RuntimeMenuProjection {
        captureSnapshot?.menuProjection ?? snapshot.status.menuProjection
    }

    func start() async {
        let task: Task<AppLifecycleSnapshot, Error>
        if let startupTask {
            task = startupTask
        } else {
            let lifecycle = lifecycle
            let initialStatus = initialStatus
            let createdTask = Task {
                try await lifecycle.launch(initialStatus: initialStatus)
            }
            startupTask = createdTask
            task = createdTask
        }
        do {
            let launched = try await task.value
            if launched.recoveryReason == .interruptedCapture {
                await captureCoordinator.restoreOpenGap(
                    reason: .processStopped,
                    startedAt: launched.interruptedAt ?? Date()
                )
            }
            snapshot = launched
        } catch {
            snapshot = AppLifecycleSnapshot(
                status: .permissionRequired,
                launchCount: 1,
                mainWindowVisible: false,
                recoveryReason: .invalidPersistedState
            )
        }
    }

    func performPrimaryAction() {
        if let captureSnapshot, let latestCaptureInputs {
            let shouldEnable = captureSnapshot.cause == .paused
            reconcileCapture(
                latestCaptureInputs.replacing(recordingEnabled: shouldEnable)
            )
            return
        }
        Task {
            await start()
            do {
                captureSnapshot = nil
                snapshot = try await lifecycle.performPrimaryAction()
            } catch {
                snapshot = AppLifecycleSnapshot(
                    status: .permissionRequired,
                    launchCount: snapshot.launchCount,
                    mainWindowVisible: snapshot.mainWindowVisible,
                    recoveryReason: .invalidPersistedState
                )
            }
        }
    }

    func transition(to status: LocalMemoryRuntimeStatus) {
        Task {
            await start()
            do {
                captureSnapshot = nil
                snapshot = try await lifecycle.transition(to: status)
            } catch {
                snapshot = AppLifecycleSnapshot(
                    status: .permissionRequired,
                    launchCount: snapshot.launchCount,
                    mainWindowVisible: snapshot.mainWindowVisible,
                    recoveryReason: .invalidPersistedState
                )
            }
        }
    }

    func setMainWindowVisible(_ visible: Bool) {
        Task {
            await start()
            if let updated = try? await lifecycle.setMainWindowVisible(visible) {
                snapshot = updated
            }
        }
    }

    func applyCaptureSnapshot(_ captureSnapshot: CaptureLifecycleSnapshot) {
        self.captureSnapshot = captureSnapshot
        snapshot = AppLifecycleSnapshot(
            status: captureSnapshot.runtimeStatus,
            launchCount: snapshot.launchCount,
            mainWindowVisible: snapshot.mainWindowVisible,
            recoveryReason: snapshot.recoveryReason,
            interruptedAt: snapshot.interruptedAt
        )
        Task {
            _ = try? await lifecycle.transition(to: captureSnapshot.runtimeStatus)
        }
    }

    func reconcileCapture(_ inputs: CaptureLifecycleInputs) {
        latestCaptureInputs = inputs
        let observedAt = Date()
        let observedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        Task {
            do {
                let captureSnapshot = try await captureCoordinator.reconcile(
                    inputs,
                    observedAt: observedAt,
                    observedAtNanoseconds: observedAtNanoseconds
                )
                applyCaptureSnapshot(captureSnapshot)
            } catch {
                transition(to: .stopped)
            }
        }
    }
}

@MainActor
final class LaunchAtLoginViewModel: ObservableObject {
    @Published private(set) var snapshot = LaunchAtLoginSnapshot(
        status: .disabled,
        humanGate: nil
    )
    @Published private(set) var errorCode: String?

    private let controller: LaunchAtLoginController

    init(controller: LaunchAtLoginController = LaunchAtLoginController()) {
        self.controller = controller
    }

    var isEnabled: Bool { snapshot.status == .enabled }

    func start() async {
        snapshot = await controller.refresh()
    }

    func setEnabled(_ enabled: Bool) {
        Task {
            do {
                snapshot = try await controller.setEnabled(enabled)
                errorCode = nil
            } catch {
                snapshot = await controller.refresh()
                errorCode = "LM-LOGIN-ITEM"
            }
        }
    }
}

struct AppLaunchConfiguration {
    let opensMainWindow: Bool
    let showsMenuPreview: Bool
    let runsLM009EvidenceSequence: Bool
    let stateURL: URL
    let navigationStateURL: URL
    let onboardingStateURL: URL
    let searchPanelStateURL: URL
    let privacyPolicyStateURL: URL
    let initialStatus: LocalMemoryRuntimeStatus
    let forcedMainWindowSize: MainWindowLaunchSize?
    let preferredColorScheme: ColorScheme?
    let opensSettingsAtLaunch: Bool
    let opensOnboardingAtLaunch: Bool
    let onboardingPermissionOverrides: [OnboardingPermissionKind: OnboardingPermissionStatus]
    let suppressOnboardingSystemSettings: Bool
    let opensSearchPanelAtLaunch: Bool
    let simulatesShortcutCollision: Bool
    let measuresWarmSearchPanelAtLaunch: Bool
    let opensSettingsWithoutMainAtLaunch: Bool
    let opensPrivacySettingsAtLaunch: Bool
    let shellContentState: ShellContentState
    let shellLocalizationMode: ShellLocalizationMode

    init(arguments: [String]) {
        runsLM009EvidenceSequence = arguments.contains("--lm009-evidence-sequence")
        showsMenuPreview =
            arguments.contains("--lm009-menu-preview")
            || runsLM009EvidenceSequence
        opensPrivacySettingsAtLaunch = arguments.contains("--lm056-open-privacy-settings")
        opensSettingsAtLaunch =
            arguments.contains("--lm010-open-settings")
            || arguments.contains("--lm015-shortcut-collision")
            || opensPrivacySettingsAtLaunch
        opensSearchPanelAtLaunch = arguments.contains("--lm015-search-panel")
        simulatesShortcutCollision = arguments.contains("--lm015-shortcut-collision")
        measuresWarmSearchPanelAtLaunch = arguments.contains("--lm015-measure-warm")
        opensSettingsWithoutMainAtLaunch =
            simulatesShortcutCollision
            || opensPrivacySettingsAtLaunch
        if let index = arguments.firstIndex(of: "--lm016-content-state"),
            arguments.indices.contains(index + 1)
        {
            switch arguments[index + 1] {
            case "empty": shellContentState = .empty
            case "loading": shellContentState = .loading(elapsedMilliseconds: 301)
            case "error": shellContentState = .failure
            default: shellContentState = .ready
            }
        } else {
            shellContentState = .ready
        }
        shellLocalizationMode =
            arguments.contains("--lm016-pseudo-localization")
            ? .pseudo
            : .english
        let forcesOnboarding = arguments.contains("--lm014-onboarding")
        let suppressesOnboarding =
            arguments.contains("--lm014-skip-onboarding")
            || arguments.contains { argument in
                argument.hasPrefix("--lm008-")
                    || argument.hasPrefix("--lm009-")
                    || argument.hasPrefix("--lm010-")
                    || argument.hasPrefix("--lm015-")
                    || argument.hasPrefix("--lm016-")
                    || argument.hasPrefix("--lm019-")
                    || argument.hasPrefix("--lm020-")
                    || argument.hasPrefix("--lm021-")
                    || argument.hasPrefix("--lm022-")
                    || argument.hasPrefix("--lm023-")
                    || argument.hasPrefix("--lm024-")
                    || argument.hasPrefix("--lm056-")
                    || argument.hasPrefix("--capture-")
                    || argument.hasPrefix("--context-")
                    || argument == "--s3-s4-spike"
            }
        opensOnboardingAtLaunch = forcesOnboarding || !suppressesOnboarding
        suppressOnboardingSystemSettings = arguments.contains(
            "--lm014-suppress-system-settings"
        )
        opensMainWindow =
            showsMenuPreview
            || arguments.contains("--lm009-open-main")
            || arguments.contains("--lm010-shell")
            || (opensSettingsAtLaunch && !opensSettingsWithoutMainAtLaunch)
            || opensSearchPanelAtLaunch
            || arguments.contains("--request-capture-permissions")
            || arguments.contains("--capture-capability-probe")
            || arguments.contains("--capture-spike")
            || arguments.contains("--context-spike")
            || arguments.contains("--lm019-export-lifecycle")
            || arguments.contains("--lm020-export-resolver")
            || arguments.contains("--lm008-s6-spike")

        if let index = arguments.firstIndex(of: "--lm009-state-file"),
            arguments.indices.contains(index + 1)
        {
            stateURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            stateURL = Self.defaultStateURL(fileName: "runtime-state.json")
        }

        if let index = arguments.firstIndex(of: "--lm010-navigation-state-file"),
            arguments.indices.contains(index + 1)
        {
            navigationStateURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            navigationStateURL = Self.defaultStateURL(fileName: "navigation-state.json")
        }

        if let index = arguments.firstIndex(of: "--lm014-onboarding-state-file"),
            arguments.indices.contains(index + 1)
        {
            onboardingStateURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            onboardingStateURL = Self.defaultStateURL(fileName: "onboarding-state.json")
        }

        if let index = arguments.firstIndex(of: "--lm015-search-panel-state-file"),
            arguments.indices.contains(index + 1)
        {
            searchPanelStateURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            searchPanelStateURL = Self.defaultStateURL(fileName: "search-panel-state.json")
        }

        if let index = arguments.firstIndex(of: "--lm056-policy-state-file"),
            arguments.indices.contains(index + 1)
        {
            privacyPolicyStateURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            privacyPolicyStateURL = Self.defaultStateURL(fileName: "privacy-policy.json")
        }

        var permissionOverrides: [OnboardingPermissionKind: OnboardingPermissionStatus] = [:]
        if let index = arguments.firstIndex(of: "--lm014-screen-permission"),
            arguments.indices.contains(index + 1),
            let status = OnboardingPermissionStatus(rawValue: arguments[index + 1])
        {
            permissionOverrides[.screenRecording] = status
        }
        if let index = arguments.firstIndex(of: "--lm014-accessibility-permission"),
            arguments.indices.contains(index + 1),
            let status = OnboardingPermissionStatus(rawValue: arguments[index + 1])
        {
            permissionOverrides[.accessibility] = status
        }
        onboardingPermissionOverrides = permissionOverrides

        if let index = arguments.firstIndex(of: "--lm009-runtime"),
            arguments.indices.contains(index + 1),
            let parsed = Self.parseStatus(arguments[index + 1])
        {
            initialStatus = parsed
        } else {
            initialStatus = showsMenuPreview ? .recording : .targetUnavailable
        }

        if let index = arguments.firstIndex(of: "--lm010-window-size"),
            arguments.indices.contains(index + 1)
        {
            forcedMainWindowSize = MainWindowLaunchSize(rawValue: arguments[index + 1])
        } else {
            forcedMainWindowSize = nil
        }

        if let index = arguments.firstIndex(of: "--lm010-appearance"),
            arguments.indices.contains(index + 1)
        {
            switch arguments[index + 1] {
            case "light": preferredColorScheme = .light
            case "dark": preferredColorScheme = .dark
            default: preferredColorScheme = nil
            }
        } else {
            preferredColorScheme = nil
        }
    }

    private static func parseStatus(_ rawValue: String) -> LocalMemoryRuntimeStatus? {
        switch rawValue {
        case "recording": .recording
        case "paused": .paused
        case "idle": .idle
        case "sleeping": .sleeping
        case "target-unavailable": .targetUnavailable
        case "permission-required": .permissionRequired
        case "disk-full": .diskFull
        case "stopped": .stopped
        case "indexing": .indexing
        default: nil
        }
    }

    private static func defaultStateURL(fileName: String) -> URL {
        do {
            return try ArchivePathProvider.prepare().root.appending(path: fileName)
        } catch {
            preconditionFailure("Local Memory application support is unavailable: \(error)")
        }
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppLifecycleViewModel
    @ObservedObject var onboardingModel: OnboardingViewModel
    let opensMainWindowAtLaunch: Bool
    let opensOnboardingAtLaunch: Bool
    let opensSearchPanelAtLaunch: Bool
    let measuresWarmSearchPanelAtLaunch: Bool
    let opensSettingsWithoutMainAtLaunch: Bool
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var hasHandledLaunch = false

    var body: some View {
        Image(systemName: model.menuProjection.statusSymbol)
            .accessibilityLabel(model.menuProjection.statusLabel)
            .accessibilityIdentifier("menuBar.statusItem")
            .task {
                guard !hasHandledLaunch else { return }
                hasHandledLaunch = true
                await onboardingModel.start()
                if opensOnboardingAtLaunch, !onboardingModel.snapshot.isComplete {
                    openWindow(id: "onboarding")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } else if opensSearchPanelAtLaunch {
                    await searchPanelCoordinator.start()
                    openWindow(id: "main")
                    await Task.yield()
                    searchPanelCoordinator.present()
                    if measuresWarmSearchPanelAtLaunch {
                        await Task.yield()
                        searchPanelCoordinator.present()
                    }
                } else if opensSettingsWithoutMainAtLaunch {
                    await searchPanelCoordinator.start()
                    openSettings()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } else if opensMainWindowAtLaunch {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct AppMenuBarContent: View {
    @ObservedObject var model: AppLifecycleViewModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarStatusPanel(
            model: model,
            openMainWindow: {
                searchPanelCoordinator.present()
            },
            openApplication: {
                navigationModel.select(section: .search)
                openWindow(id: "main")
            },
            openTimeline: {
                navigationModel.select(section: .timeline)
                openWindow(id: "main")
            },
            openSettings: { openSettings() },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}

struct MenuBarStatusPanel: View {
    @ObservedObject var model: AppLifecycleViewModel
    let openMainWindow: () -> Void
    let openApplication: () -> Void
    let openTimeline: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.menuProjection.statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.menuProjection.statusLabel)
                        .font(.headline)
                        .accessibilityLabel(model.menuProjection.statusLabel)
                        .accessibilityIdentifier("menu.status")
                    Text(model.menuProjection.detailLabel ?? "Foreground window only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.menuProjection.detailLabel != nil {
                        Text("Foreground window only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(12)

            Divider()

            Button(model.menuProjection.primaryActionLabel) {
                switch model.snapshot.status {
                case .recording, .paused, .idle, .sleeping, .targetUnavailable, .indexing:
                    model.performPrimaryAction()
                case .permissionRequired:
                    openSettings()
                case .diskFull, .stopped:
                    openSettings()
                }
            }
            .accessibilityIdentifier("menu.primaryAction")

            Divider()

            Button("Search Memory…", action: openMainWindow)
                .keyboardShortcut("f")
                .accessibilityIdentifier("menu.search")
            Button("Open Timeline", action: openTimeline)
                .accessibilityIdentifier("menu.timeline")
            Button("Forget Last 15 Minutes…") {}
                .disabled(true)
                .accessibilityIdentifier("menu.forgetRecent")
            Button("Open Local Memory", action: openApplication)
                .accessibilityIdentifier("menu.openMain")
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",")
                .accessibilityIdentifier("menu.settings")

            Divider()

            Button("Quit", action: quit)
                .keyboardShortcut("q")
                .accessibilityIdentifier("menu.quit")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu.panel")
    }

    private var statusColor: Color {
        switch model.snapshot.status {
        case .recording: .red
        case .paused, .idle, .sleeping, .targetUnavailable: .orange
        case .permissionRequired, .diskFull, .stopped: .orange
        case .indexing: .indigo
        }
    }
}

struct AppShellPlaceholderView: View {
    @ObservedObject var model: AppLifecycleViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.stack.badge.clock")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Local Memory")
                .font(.largeTitle)
                .accessibilityIdentifier("bootstrap.title")
            Label(
                model.menuProjection.statusLabel,
                systemImage: model.menuProjection.statusSymbol
            )
            .font(.headline)
            .accessibilityIdentifier("main.runtimeStatus")
            Text("Your history stays on this Mac.")
                .foregroundStyle(.secondary)
            Text("Only your approved foreground window is recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.setMainWindowVisible(true) }
        .onDisappear { model.setMainWindowVisible(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bootstrap.root")
    }
}

struct LM009MenuPreviewView: View {
    @ObservedObject var model: AppLifecycleViewModel
    let runsEvidenceSequence: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Menu Bar")
                .font(.title2)
            MenuBarStatusPanel(
                model: model,
                openMainWindow: {},
                openApplication: {},
                openTimeline: {},
                openSettings: {},
                quit: {}
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 520)
        .onAppear { model.setMainWindowVisible(true) }
        .onDisappear { model.setMainWindowVisible(false) }
        .task {
            guard runsEvidenceSequence else { return }
            // Leave enough lead-in for the window-only recorder to attach and
            // visibly establish the initial recording state.
            try? await Task.sleep(for: .seconds(2.5))
            for status in Self.evidenceStatuses {
                guard !Task.isCancelled else { return }
                model.transition(to: status)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityIdentifier("lm009.menuPreview")
    }

    private static let evidenceStatuses: [LocalMemoryRuntimeStatus] = [
        .paused,
        .idle,
        .sleeping,
        .targetUnavailable,
        .permissionRequired,
        .diskFull,
        .stopped,
        .indexing,
        .recording,
    ]
}
