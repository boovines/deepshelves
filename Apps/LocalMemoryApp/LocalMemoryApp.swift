import AppKit
import Darwin
import Foundation
import MemoryCapture
import MemoryContracts
import MemoryDesignSystem
import MemoryEnrichment
import MemorySearch
import MemoryStore
import SwiftUI

@main
struct LocalMemoryApp: App {
    @StateObject private var lifecycleModel: AppLifecycleViewModel
    @StateObject private var launchAtLoginModel: LaunchAtLoginViewModel
    @StateObject private var navigationModel: MainNavigationViewModel
    @StateObject private var onboardingModel: OnboardingViewModel
    @StateObject private var searchPanelCoordinator: GlobalSearchPanelCoordinator
    @StateObject private var searchModel: SearchSessionModel
    @StateObject private var searchFilterModel: SearchFilterSessionModel
    @StateObject private var privacySettingsModel: PrivacySettingsViewModel
    @StateObject private var archiveSecurityModel: ArchiveSecurityViewModel
    private let shellKeyboardMonitor: ShellKeyboardCommandMonitor

    private let launchConfiguration: AppLaunchConfiguration
    private let capabilityProbeOutput: String?
    private let shouldRequestCapturePermissions: Bool
    private let captureSpikeOutputDirectory: String?
    private let captureSpikeDurationSeconds: Double
    private let captureSpikeStaticMode: Bool
    private let captureSpikeCrashActiveMode: Bool
    private let lm019LifecycleOutput: String?
    private let lm020ResolverOutput: String?
    private let contextSpikeOutputDirectory: String?
    private let vectorSpikeArguments: (output: String, imageModel: String, textModel: String)?
    private let s5SpikeArguments: (output: String, unsignedProbe: String, media: String)?
    private let s6SpikeArguments: (output: String, media: String)?
    private let s7SpikeArguments: (output: String, media: String)?
    private let s6AutoExit: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        Self.exportLM017SchemaAndExitIfRequested(arguments: arguments)
        Self.exportLM018FaultsAndExitIfRequested(arguments: arguments)
        Self.exportLM021BrowserContextAndExitIfRequested(arguments: arguments)
        Self.exportLM022PrivacyPolicyAndExitIfRequested(arguments: arguments)
        Self.exportLM023ActivityMonitorAndExitIfRequested(arguments: arguments)
        Self.exportLM024EpochCaptureAndExitIfRequested(arguments: arguments)
        let configuration = AppLaunchConfiguration(arguments: arguments)
        launchConfiguration = configuration
        shellKeyboardMonitor = ShellKeyboardCommandMonitor()
        let archiveSecurityModel = ArchiveSecurityViewModel(
            usesDeterministicStore: arguments.contains("--lm019-export-lifecycle")
                || arguments.contains("--lm020-export-resolver")
        )
        _archiveSecurityModel = StateObject(wrappedValue: archiveSecurityModel)
        let lifecycleModel = AppLifecycleViewModel(
            stateURL: configuration.stateURL,
            initialStatus: configuration.initialStatus,
            gapSink: archiveSecurityModel.database
        )
        _lifecycleModel = StateObject(wrappedValue: lifecycleModel)
        _launchAtLoginModel = StateObject(wrappedValue: LaunchAtLoginViewModel())
        let navigationModel = MainNavigationViewModel(stateURL: configuration.navigationStateURL)
        _navigationModel = StateObject(wrappedValue: navigationModel)
        let searchModel = AppSearchComposition.makeModel(
            database: archiveSecurityModel.database,
            fixtureMode: configuration.searchFixtureMode
        )
        _searchModel = StateObject(wrappedValue: searchModel)
        let searchFilterModel = AppSearchComposition.makeFilterModel(
            searchModel: searchModel,
            database: archiveSecurityModel.database,
            fixtureMode: configuration.searchFixtureMode
        )
        _searchFilterModel = StateObject(wrappedValue: searchFilterModel)
        _searchPanelCoordinator = StateObject(
            wrappedValue: GlobalSearchPanelCoordinator(
                navigationModel: navigationModel,
                lifecycleModel: lifecycleModel,
                searchModel: searchModel,
                searchFilterModel: searchFilterModel,
                stateURL: configuration.searchPanelStateURL,
                simulatesShortcutCollision: configuration.simulatesShortcutCollision
            )
        )
        _onboardingModel = StateObject(
            wrappedValue: OnboardingViewModel(
                stateURL: configuration.onboardingStateURL,
                overrides: configuration.onboardingPermissionOverrides,
                suppressSystemSettings: configuration.suppressOnboardingSystemSettings
            )
        )
        _privacySettingsModel = StateObject(
            wrappedValue: PrivacySettingsViewModel(
                stateURL: configuration.privacyPolicyStateURL
            )
        )
        s6AutoExit = arguments.contains("--lm008-s6-auto-exit")
        shouldRequestCapturePermissions = arguments.contains("--request-capture-permissions")
        captureSpikeStaticMode = arguments.contains("--capture-spike-static")
        captureSpikeCrashActiveMode = arguments.contains("--capture-spike-crash-active")
        if let flagIndex = arguments.firstIndex(of: "--lm019-export-lifecycle"),
            arguments.indices.contains(flagIndex + 1)
        {
            lm019LifecycleOutput = arguments[flagIndex + 1]
        } else {
            lm019LifecycleOutput = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--lm020-export-resolver"),
            arguments.indices.contains(flagIndex + 1)
        {
            lm020ResolverOutput = arguments[flagIndex + 1]
        } else {
            lm020ResolverOutput = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--context-spike"),
            arguments.indices.contains(flagIndex + 1)
        {
            contextSpikeOutputDirectory = arguments[flagIndex + 1]
        } else {
            contextSpikeOutputDirectory = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--s3-s4-spike"),
            arguments.indices.contains(flagIndex + 3)
        {
            vectorSpikeArguments = (
                arguments[flagIndex + 1],
                arguments[flagIndex + 2],
                arguments[flagIndex + 3]
            )
        } else {
            vectorSpikeArguments = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--lm008-s5-spike"),
            arguments.indices.contains(flagIndex + 3)
        {
            s5SpikeArguments = (
                arguments[flagIndex + 1],
                arguments[flagIndex + 2],
                arguments[flagIndex + 3]
            )
        } else {
            s5SpikeArguments = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--lm008-s6-spike"),
            arguments.indices.contains(flagIndex + 2)
        {
            s6SpikeArguments = (arguments[flagIndex + 1], arguments[flagIndex + 2])
        } else {
            s6SpikeArguments = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--lm008-s7-spike"),
            arguments.indices.contains(flagIndex + 2)
        {
            s7SpikeArguments = (arguments[flagIndex + 1], arguments[flagIndex + 2])
        } else {
            s7SpikeArguments = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-spike"),
            arguments.indices.contains(flagIndex + 1)
        {
            captureSpikeOutputDirectory = arguments[flagIndex + 1]
        } else {
            captureSpikeOutputDirectory = nil
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-spike-duration"),
            arguments.indices.contains(flagIndex + 1)
        {
            captureSpikeDurationSeconds = Double(arguments[flagIndex + 1]) ?? 10
        } else {
            captureSpikeDurationSeconds = 10
        }
        if let flagIndex = arguments.firstIndex(of: "--capture-capability-probe"),
            arguments.indices.contains(flagIndex + 1)
        {
            capabilityProbeOutput = arguments[flagIndex + 1]
        } else {
            capabilityProbeOutput = nil
        }
        if let vectorSpikeArguments {
            Self.launchVectorSpike(vectorSpikeArguments)
        }
        if let s5SpikeArguments {
            Self.launchS5Spike(s5SpikeArguments)
        }
        if let s7SpikeArguments {
            Self.launchS7Spike(s7SpikeArguments)
        }
        LM008ChildModes.launchIfRequested(arguments: arguments)
    }

    private static func exportLM017SchemaAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm017-export-schema"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            let archive = try ArchiveDatabase.deterministicTestStore()
            let evidence = """
                -- LM-017: SQLite schema exported from a freshly migrated deterministic store.
                -- Migration: v1_archive_schema; schema_version=1; foreign_keys=ON.

                \(try archive.schemaSQL())
                """
            try Data(evidence.utf8).write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-017 schema export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func exportLM018FaultsAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm018-export-faults"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(LM018FaultHarness.run()).write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-018 fault export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func exportLM021BrowserContextAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm021-export-browser-context"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            try LM021BrowserContextHarness.run().write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-021 browser context export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func exportLM022PrivacyPolicyAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm022-export-privacy-policy"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            try LM022PrivacyPolicyHarness.runBlocking().write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-022 privacy policy export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func exportLM023ActivityMonitorAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm023-export-activity-monitor"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            try LM023ActivityMonitorHarness.runBlocking().write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-023 activity monitor export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func exportLM024EpochCaptureAndExitIfRequested(arguments: [String]) {
        guard let exportIndex = arguments.firstIndex(of: "--lm024-export-epoch-capture"),
            arguments.indices.contains(exportIndex + 1)
        else {
            return
        }
        do {
            try LM024EpochCaptureHarness.runBlocking().write(
                to: URL(fileURLWithPath: arguments[exportIndex + 1]),
                options: .atomic
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("LM-024 epoch capture export failed: \(error)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        Window("Local Memory", id: "main") {
            Group {
                if launchConfiguration.showsMenuPreview {
                    LM009MenuPreviewView(
                        model: lifecycleModel,
                        runsEvidenceSequence: launchConfiguration.runsLM009EvidenceSequence
                    )
                } else if let s6SpikeArguments {
                    S6SpikeView(
                        outputDirectory: URL(
                            fileURLWithPath: s6SpikeArguments.output,
                            isDirectory: true
                        ),
                        mediaURL: URL(fileURLWithPath: s6SpikeArguments.media),
                        autoExit: s6AutoExit
                    )
                } else if contextSpikeOutputDirectory != nil {
                    ContextSpikeTargetView()
                } else if lm019LifecycleOutput != nil || lm020ResolverOutput != nil {
                    CaptureSpikeTargetView(animated: true)
                } else if captureSpikeOutputDirectory == nil {
                    MainShellView(
                        lifecycleModel: lifecycleModel,
                        navigationModel: navigationModel,
                        searchModel: searchModel,
                        searchFilterModel: searchFilterModel,
                        forcedWindowSize: launchConfiguration.forcedMainWindowSize,
                        opensSettingsAtLaunch: launchConfiguration.opensSettingsAtLaunch,
                        contentState: launchConfiguration.shellContentState,
                        localizationMode: launchConfiguration.shellLocalizationMode
                    )
                } else {
                    CaptureSpikeTargetView(animated: captureSpikeCrashActiveMode)
                }
            }
            .preferredColorScheme(launchConfiguration.preferredColorScheme)
            .task {
                if let lm019LifecycleOutput {
                    do {
                        try await LM019LifecycleHarness.run(
                            outputURL: URL(fileURLWithPath: lm019LifecycleOutput)
                        )
                        NSApplication.shared.terminate(nil)
                    } catch {
                        FileHandle.standardError.write(
                            Data("LM-019 lifecycle export failed: \(error)\n".utf8)
                        )
                        Darwin.exit(EXIT_FAILURE)
                    }
                    return
                }
                if let lm020ResolverOutput {
                    do {
                        try await LM020WindowResolverHarness.run(
                            outputURL: URL(fileURLWithPath: lm020ResolverOutput)
                        )
                        NSApplication.shared.terminate(nil)
                    } catch {
                        FileHandle.standardError.write(
                            Data("LM-020 resolver export failed: \(error)\n".utf8)
                        )
                        Darwin.exit(EXIT_FAILURE)
                    }
                    return
                }
                if let contextSpikeOutputDirectory {
                    await ContextSpikeHarness.run(
                        outputDirectory: URL(fileURLWithPath: contextSpikeOutputDirectory)
                    )
                    return
                }
                if shouldRequestCapturePermissions {
                    _ = CaptureCapabilities.requestFromUser()
                    return
                }
                if let captureSpikeOutputDirectory {
                    await CaptureSpikeHarness.run(
                        outputDirectory: URL(fileURLWithPath: captureSpikeOutputDirectory),
                        durationSeconds: captureSpikeDurationSeconds,
                        staticMode: captureSpikeStaticMode
                    )
                    return
                }
                guard let capabilityProbeOutput else {
                    return
                }
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(CaptureCapabilities.current())
                    try data.write(
                        to: URL(fileURLWithPath: capabilityProbeOutput), options: .atomic)
                } catch {
                    FileHandle.standardError.write(Data("capture capability probe failed\n".utf8))
                }
                NSApplication.shared.terminate(nil)
            }
        }
        .defaultSize(
            width: launchConfiguration.forcedMainWindowSize?.width
                ?? CGFloat(MainWindowDefaults.defaultWidth),
            height: launchConfiguration.forcedMainWindowSize?.height
                ?? CGFloat(MainWindowDefaults.defaultHeight)
        )
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            LocalMemoryCommands(
                navigationModel: navigationModel,
                searchPanelCoordinator: searchPanelCoordinator
            )
        }

        Settings {
            LocalMemorySettingsView(
                lifecycleModel: lifecycleModel,
                launchAtLoginModel: launchAtLoginModel,
                searchPanelCoordinator: searchPanelCoordinator,
                privacySettingsModel: privacySettingsModel,
                archiveSecurityModel: archiveSecurityModel,
                opensPrivacyAtLaunch: launchConfiguration.opensPrivacySettingsAtLaunch
            )
            .preferredColorScheme(launchConfiguration.preferredColorScheme)
        }
        .defaultSize(
            width: CGFloat(MainWindowDefaults.settingsWidth),
            height: CGFloat(MainWindowDefaults.settingsHeight)
        )

        Window("Welcome to Local Memory", id: "onboarding") {
            OnboardingSceneRoot(model: onboardingModel)
                .preferredColorScheme(launchConfiguration.preferredColorScheme)
        }
        .defaultSize(
            width: CGFloat(OnboardingDefaults.windowWidth),
            height: CGFloat(OnboardingDefaults.windowHeight)
        )
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AppMenuBarContent(
                model: lifecycleModel,
                navigationModel: navigationModel,
                searchPanelCoordinator: searchPanelCoordinator
            )
        } label: {
            MenuBarStatusLabel(
                model: lifecycleModel,
                onboardingModel: onboardingModel,
                opensMainWindowAtLaunch: launchConfiguration.opensMainWindow,
                opensOnboardingAtLaunch: launchConfiguration.opensOnboardingAtLaunch,
                opensSearchPanelAtLaunch: launchConfiguration.opensSearchPanelAtLaunch,
                measuresWarmSearchPanelAtLaunch: launchConfiguration
                    .measuresWarmSearchPanelAtLaunch,
                opensSettingsWithoutMainAtLaunch: launchConfiguration
                    .opensSettingsWithoutMainAtLaunch,
                searchPanelCoordinator: searchPanelCoordinator
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static func launchVectorSpike(
        _ arguments: (output: String, imageModel: String, textModel: String)
    ) {
        Task.detached(priority: .userInitiated) {
            let output = URL(fileURLWithPath: arguments.output, isDirectory: true)
            do {
                _ = try await S3S4SpikeRunner.run(
                    outputDirectory: output,
                    referenceImageModelURL: URL(
                        fileURLWithPath: arguments.imageModel,
                        isDirectory: true
                    ),
                    referenceTextModelURL: URL(
                        fileURLWithPath: arguments.textModel,
                        isDirectory: true
                    )
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                try? FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                try? Data("S3/S4 spike failed: \(error)\n".utf8).write(
                    to: output.appending(path: "s3-s4-error.log"),
                    options: .atomic
                )
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    private static func launchS5Spike(
        _ arguments: (output: String, unsignedProbe: String, media: String)
    ) {
        Task.detached(priority: .userInitiated) {
            let output = URL(fileURLWithPath: arguments.output, isDirectory: true)
            do {
                guard let executable = Bundle.main.executableURL else {
                    throw CocoaError(.executableNotLoadable)
                }
                _ = try await S5SpikeRunner.run(
                    outputDirectory: output,
                    signedExecutableURL: executable,
                    unsignedProbeURL: URL(fileURLWithPath: arguments.unsignedProbe),
                    deletionMediaFixtureURL: URL(fileURLWithPath: arguments.media)
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                try? FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                try? Data("S5 spike failed: \(error)\n".utf8).write(
                    to: output.appending(path: "s5-error.log"),
                    options: .atomic
                )
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    private static func launchS7Spike(
        _ arguments: (output: String, media: String)
    ) {
        Task.detached(priority: .userInitiated) {
            let output = URL(fileURLWithPath: arguments.output, isDirectory: true)
            do {
                guard let executable = Bundle.main.executableURL else {
                    throw CocoaError(.executableNotLoadable)
                }
                _ = try await S7OfflineSpikeRunner.run(
                    outputDirectory: output,
                    mediaFixtureURL: URL(fileURLWithPath: arguments.media),
                    signedExecutableURL: executable
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                try? FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                try? Data("S7 spike failed: \(error)\n".utf8).write(
                    to: output.appending(path: "s7-error.log"),
                    options: .atomic
                )
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }
}

struct BootstrapView: View {
    let schemaVersion: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.clock")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Local Memory")
                .font(.largeTitle)
                .accessibilityIdentifier("bootstrap.title")
            Text("Your history stays on this Mac.")
                .foregroundStyle(.secondary)
            Text("Bootstrap contract v\(schemaVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 640, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bootstrap.root")
    }
}
