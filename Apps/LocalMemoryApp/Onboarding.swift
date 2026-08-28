import AppKit
import MemoryCapture
import MemoryDesignSystem
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var snapshot: OnboardingSnapshot = .default
    @Published private(set) var isRestored = false

    private let coordinator: OnboardingCoordinator
    private let overrides: [OnboardingPermissionKind: OnboardingPermissionStatus]
    private let suppressSystemSettings: Bool
    private var startupTask: Task<OnboardingSnapshot, Error>?

    init(
        stateURL: URL,
        overrides: [OnboardingPermissionKind: OnboardingPermissionStatus],
        suppressSystemSettings: Bool
    ) {
        coordinator = OnboardingCoordinator(
            store: FileOnboardingStateStore(fileURL: stateURL)
        )
        self.overrides = overrides
        self.suppressSystemSettings = suppressSystemSettings
    }

    func start() async {
        if isRestored { return }
        let task: Task<OnboardingSnapshot, Error>
        if let startupTask {
            task = startupTask
        } else {
            let coordinator = coordinator
            let overrides = overrides
            let created = Task { try await coordinator.launch(overrides: overrides) }
            startupTask = created
            task = created
        }
        do {
            var restored = try await task.value
            if overrides.isEmpty {
                let capabilities = CaptureCapabilities.current()
                let screenStatus = Self.resolvedStatus(
                    granted: capabilities.screenRecording,
                    previous: restored.screenRecording,
                    explicitActions: restored.explicitPermissionActions[.screenRecording, default: 0]
                )
                let accessibilityStatus = Self.resolvedStatus(
                    granted: capabilities.accessibility,
                    previous: restored.accessibility,
                    explicitActions: restored.explicitPermissionActions[.accessibility, default: 0]
                )
                restored = try await coordinator.updatePermission(
                    .screenRecording,
                    status: screenStatus
                )
                restored = try await coordinator.updatePermission(
                    .accessibility,
                    status: accessibilityStatus
                )
            }
            snapshot = restored
        } catch {
            snapshot = .default
        }
        isRestored = true
    }

    func select(step: OnboardingStep) {
        perform { try await $0.select(step: step) }
    }

    func advance() {
        perform { try await $0.advance() }
    }

    func retreat() {
        perform { try await $0.retreat() }
    }

    func complete() {
        Task {
            await start()
            do {
                snapshot = try await coordinator.complete()
            } catch {}
        }
    }

    func openSystemSettings(for kind: OnboardingPermissionKind) {
        Task {
            await start()
            do {
                snapshot = try await coordinator.registerExplicitPermissionAction(kind)
                guard !suppressSystemSettings, let url = Self.systemSettingsURL(for: kind) else {
                    return
                }
                NSWorkspace.shared.open(url)
            } catch {}
        }
    }

    private func perform(
        _ operation: @escaping (OnboardingCoordinator) async throws -> OnboardingSnapshot
    ) {
        Task {
            await start()
            if let updated = try? await operation(coordinator) {
                snapshot = updated
            }
        }
    }

    private static func resolvedStatus(
        granted: Bool,
        previous: OnboardingPermissionStatus,
        explicitActions: Int
    ) -> OnboardingPermissionStatus {
        if granted { return .granted }
        if previous == .granted { return .revoked }
        if explicitActions > 0 { return .denied }
        return .notDetermined
    }

    private static func systemSettingsURL(for kind: OnboardingPermissionKind) -> URL? {
        switch kind {
        case .screenRecording:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        case .accessibility:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        case .microphone:
            nil
        }
    }
}

struct LocalMemoryOnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    private let footerHeight: CGFloat = 64

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: MemorySpacing.small) {
                Text("Local Memory")
                    .font(MemoryTypeToken.headline.font)
                    .padding(.horizontal, MemorySpacing.small)
                    .padding(.bottom, MemorySpacing.small)
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Button {
                        model.select(step: step)
                    } label: {
                        Label("\(step.number)  \(step.title)", systemImage: step.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, MemorySpacing.small)
                    .frame(height: MemoryControlHeight.standard)
                    .background(
                        model.snapshot.step == step
                            ? MemoryColorToken.surfaceSelected.color
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: MemoryRadius.control)
                    )
                    .accessibilityLabel("Step \(step.number) of 4, \(step.title)")
                    .accessibilityIdentifier("onboarding.step.\(step.rawValue)")
                }
                Spacer()
            }
            .padding(MemorySpacing.medium)
            .frame(height: CGFloat(OnboardingDefaults.windowHeight))
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 190)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.snapshot.step {
                    case .welcome:
                        OnboardingWelcomeStep()
                    case .permissions:
                        OnboardingPermissionsStep(model: model)
                    case .privacy:
                        OnboardingPrivacyStep()
                    case .ready:
                        OnboardingReadyStep()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(
                    height: CGFloat(OnboardingDefaults.windowHeight) - footerHeight - 1
                )
                .clipped()

                Divider()
                OnboardingFooter(model: model)
                    .frame(height: footerHeight)
            }
            .frame(height: CGFloat(OnboardingDefaults.windowHeight))
            .clipped()
        }
        .frame(
            width: CGFloat(OnboardingDefaults.windowWidth),
            height: CGFloat(OnboardingDefaults.windowHeight)
        )
        .disabled(!model.isRestored)
        .task { await model.start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
    }

}

struct OnboardingSceneRoot: View {
    @ObservedObject var model: OnboardingViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LocalMemoryOnboardingView(model: model)
            .background(OnboardingWindowConfigurator())
            .onChange(of: model.snapshot.isComplete) { _, isComplete in
                guard isComplete else { return }
                dismissWindow(id: "onboarding")
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct OnboardingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        OnboardingWindowAnchor()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class OnboardingWindowAnchor: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.setContentSize(
            NSSize(
                width: OnboardingDefaults.windowWidth,
                height: OnboardingDefaults.windowHeight
            )
        )
        window.center()
    }
}

private struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: MemorySpacing.large) {
            Image(systemName: "rectangle.stack.badge.clock")
                .font(MemoryTypeToken.title2.font)
                .foregroundStyle(MemoryColorToken.accent.color)
                .accessibilityHidden(true)
            Text("Your screen memory stays on this Mac")
                .font(MemoryTypeToken.title2.font)
                .accessibilityIdentifier("onboarding.heading")
            Text("Local Memory helps you find something you previously saw. Normal use is local-only: no telemetry, cloud sync, or runtime downloads.")
                .font(MemoryTypeToken.body.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            CaptureStatusBadge(state: .paused)
            Text("Recording stays off until required permission is granted.")
                .font(MemoryTypeToken.callout.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
        }
        .padding(MemorySpacing.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.welcome")
    }
}

private struct OnboardingPermissionsStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MemorySpacing.large) {
                Text("Permissions")
                    .font(MemoryTypeToken.title2.font)
                    .accessibilityIdentifier("onboarding.heading")
                Text("Choose Open System Settings for each permission. Local Memory never repeats a system prompt when this window appears or the app relaunches.")
                    .font(MemoryTypeToken.callout.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)

                permissionRow(.screenRecording)
                permissionRow(.accessibility)

                Text("Screen Recording is required to store the active window. Accessibility is requested separately and improves local text quality and context. Recording remains off when Screen Recording is denied or revoked.")
                    .font(MemoryTypeToken.callout.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
            }
            .padding(MemorySpacing.xLarge)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.permissions")
    }

    private func permissionRow(_ kind: OnboardingPermissionKind) -> some View {
        let status = model.snapshot.permissionStatus(kind)
        return PermissionRow(
            title: kind.title,
            explanation: explanation(for: kind),
            requirement: kind.requirement,
            state: status.permissionState,
            onAction: { model.openSystemSettings(for: kind) }
        )
        .accessibilityIdentifier("onboarding.permission.\(kind.rawValue)")
    }

    private func explanation(for kind: OnboardingPermissionKind) -> String {
        switch kind {
        case .screenRecording:
            "Allows only the active foreground window to be captured."
        case .accessibility:
            "Improves text quality and target-window context; capture remains usable without it."
        case .microphone:
            "Not shown during onboarding."
        }
    }
}

private struct OnboardingPrivacyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.large) {
            Text("Privacy by construction")
                .font(MemoryTypeToken.title2.font)
                .accessibilityIdentifier("onboarding.heading")
            Text(OnboardingDefaults.foregroundOnlyStatement)
                .font(MemoryTypeToken.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.foregroundStatement")
            ForegroundOnlyPreview()
            Text("Saved screenshots, searchable text, and local vectors stay in the owner-only archive. Background fixture content is never copied into the saved-image preview.")
                .font(MemoryTypeToken.callout.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
        }
        .padding(MemorySpacing.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.privacy")
    }
}

private struct ForegroundOnlyPreview: View {
    @State private var phase = false

    var body: some View {
        MemoryTokenReader { environment in
            HStack(spacing: MemorySpacing.xLarge) {
                ZStack(alignment: .topLeading) {
                    fixtureWindow(
                        title: "Background fixture window",
                        subtitle: "Not stored",
                        symbol: "rectangle.on.rectangle.slash",
                        identifier: "onboarding.preview.background",
                        selected: false
                    )
                    .frame(width: 206, height: 126)
                    .offset(x: 34, y: 30)
                    fixtureWindow(
                        title: "Active foreground fixture",
                        subtitle: "Stored",
                        symbol: "macwindow",
                        identifier: "onboarding.preview.active",
                        selected: true
                    )
                    .frame(width: 206, height: 126)
                    .offset(x: phase ? 0 : 4, y: phase ? 0 : 4)
                }
                .frame(width: 240, height: 170)
                .clipped()

                Image(systemName: "arrow.right")
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
                    .accessibilityHidden(true)

                fixtureWindow(
                    title: "Saved image",
                    subtitle: "Active window only",
                    symbol: "checkmark.shield",
                    identifier: "onboarding.preview.saved",
                    selected: true
                )
                .frame(width: 220, height: 140)
                .accessibilityLabel("Saved image contains active window only")
            }
            .frame(height: 170)
            .animation(environment.motion.animation(for: .selectionLayout), value: phase)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.2))
                    phase.toggle()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.preview")
    }

    private func fixtureWindow(
        title: String,
        subtitle: String,
        symbol: String,
        identifier: String,
        selected: Bool
    ) -> some View {
        MemoryTokenReader { environment in
            VStack(spacing: MemorySpacing.small) {
                Image(systemName: symbol)
                    .font(MemoryTypeToken.title2.font)
                    .accessibilityHidden(true)
                Text(title)
                    .font(MemoryTypeToken.headline.font)
                Text(subtitle)
                    .font(MemoryTypeToken.caption.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                selected
                    ? MemoryColorToken.surfaceSelected.color(contrast: environment.contrast)
                    : MemoryColorToken.surfaceSidebar.color,
                in: RoundedRectangle(cornerRadius: MemoryRadius.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MemoryRadius.card)
                    .stroke(
                        selected
                            ? MemoryColorToken.accent.color
                            : MemoryColorToken.borderDefault.color,
                        lineWidth: environment.hairlineWidth
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(subtitle.lowercased())")
            .accessibilityIdentifier(identifier)
        }
    }
}

private struct OnboardingReadyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.large) {
            Text("Ready")
                .font(MemoryTypeToken.title2.font)
                .accessibilityIdentifier("onboarding.heading")
            CaptureStatusBadge(state: .recording)
            readyRow("Menu bar", "Recording status and pause control stay visible")
            readyRow("Pause shortcut", "Available from the menu bar; global shortcut arrives in the next step")
            readyRow("Archive", "Stored locally in Application Support with owner-only permissions")
            readyRow("Retention", "\(OnboardingDefaults.retentionDays) days")
            readyRow("Storage cap", "\(OnboardingDefaults.storageCapGigabytes) GB")
            Text("Visual media is protected by your macOS account permissions and FileVault when enabled. Database text will use app encryption in the storage phase.")
                .font(MemoryTypeToken.callout.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
        }
        .padding(MemorySpacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.ready")
    }

    private func readyRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .font(MemoryTypeToken.body.font)
    }
}

private struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        HStack {
            Button("Back") { model.retreat() }
                .disabled(model.snapshot.step == .welcome)
                .accessibilityIdentifier("onboarding.back")
            Spacer()
            Text("Step \(model.snapshot.step.number) of 4")
                .font(MemoryTypeToken.caption.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
                .accessibilityIdentifier("onboarding.progress")
            Spacer()
            if model.snapshot.step == .ready {
                Button("Finish") { model.complete() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.finish")
            } else {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(MemorySpacing.large)
    }
}

private extension OnboardingPermissionStatus {
    var permissionState: PermissionState {
        switch self {
        case .notDetermined: .unknown
        case .granted: .granted
        case .denied: .denied
        case .revoked: .revoked
        }
    }
}
