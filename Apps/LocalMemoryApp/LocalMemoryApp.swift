import AppKit
import Darwin
import Foundation
import MemoryCapture
import MemoryContracts
import MemoryDesignSystem
import MemoryEnrichment
import MemoryStore
import SwiftUI

@main
struct LocalMemoryApp: App {
    @StateObject private var lifecycleModel: AppLifecycleViewModel
    @StateObject private var navigationModel: MainNavigationViewModel
    @StateObject private var onboardingModel: OnboardingViewModel
    @StateObject private var searchPanelCoordinator: GlobalSearchPanelCoordinator
    private let shellKeyboardMonitor: ShellKeyboardCommandMonitor

    private let launchConfiguration: AppLaunchConfiguration
    private let capabilityProbeOutput: String?
    private let shouldRequestCapturePermissions: Bool
    private let captureSpikeOutputDirectory: String?
    private let captureSpikeDurationSeconds: Double
    private let captureSpikeStaticMode: Bool
    private let captureSpikeCrashActiveMode: Bool
    private let contextSpikeOutputDirectory: String?
    private let vectorSpikeArguments: (output: String, imageModel: String, textModel: String)?
    private let s5SpikeArguments: (output: String, unsignedProbe: String, media: String)?
    private let s6SpikeArguments: (output: String, media: String)?
    private let s7SpikeArguments: (output: String, media: String)?
    private let s6AutoExit: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration = AppLaunchConfiguration(arguments: arguments)
        launchConfiguration = configuration
        shellKeyboardMonitor = ShellKeyboardCommandMonitor()
        _lifecycleModel = StateObject(
            wrappedValue: AppLifecycleViewModel(
                stateURL: configuration.stateURL,
                initialStatus: configuration.initialStatus
            )
        )
        let navigationModel = MainNavigationViewModel(stateURL: configuration.navigationStateURL)
        _navigationModel = StateObject(wrappedValue: navigationModel)
        _searchPanelCoordinator = StateObject(
            wrappedValue: GlobalSearchPanelCoordinator(
                navigationModel: navigationModel,
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
        s6AutoExit = arguments.contains("--lm008-s6-auto-exit")
        shouldRequestCapturePermissions = arguments.contains("--request-capture-permissions")
        captureSpikeStaticMode = arguments.contains("--capture-spike-static")
        captureSpikeCrashActiveMode = arguments.contains("--capture-spike-crash-active")
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
                } else if captureSpikeOutputDirectory == nil {
                    MainShellView(
                        lifecycleModel: lifecycleModel,
                        navigationModel: navigationModel,
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
                        try data.write(to: URL(fileURLWithPath: capabilityProbeOutput), options: .atomic)
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
            LocalMemorySettingsView(searchPanelCoordinator: searchPanelCoordinator)
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
                measuresWarmSearchPanelAtLaunch: launchConfiguration.measuresWarmSearchPanelAtLaunch,
                opensSettingsWithoutMainAtLaunch: launchConfiguration.opensSettingsWithoutMainAtLaunch,
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
