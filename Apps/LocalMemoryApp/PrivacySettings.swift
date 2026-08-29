import Foundation
import MemoryCapture
import MemoryContracts
import MemoryDesignSystem
import SwiftUI

enum PrivacySettingsLoadState: Equatable {
    case loading
    case ready
    case failure(String)
}

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published private(set) var loadState: PrivacySettingsLoadState = .loading
    @Published private(set) var snapshot: PrivacyPolicySettingsSnapshot?
    @Published private(set) var preview: PrivacyPolicyPreview?
    @Published private(set) var statusMessage: String?
    @Published private(set) var permissionHealth: CapturePermissionHealthSnapshot?

    private let controller: PrivacyPolicySettingsController
    private let permissionHealthMonitor: CapturePermissionHealthMonitor
    private var startupTask: Task<PrivacyPolicySettingsSnapshot, Error>?

    init(stateURL: URL) {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: defaults)
        controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: FilePrivacyPolicySettingsStore(fileURL: stateURL)
        )
        permissionHealthMonitor = CapturePermissionHealthMonitor()
    }

    func load() async {
        if loadState == .ready { return }
        let task: Task<PrivacyPolicySettingsSnapshot, Error>
        if let startupTask {
            task = startupTask
        } else {
            let controller = controller
            let created = Task { try await controller.load() }
            startupTask = created
            task = created
        }
        do {
            snapshot = try await task.value
            permissionHealth = await permissionHealthMonitor.refresh()
            loadState = .ready
        } catch {
            loadState = .failure("LM-PRIVACY-LOAD")
        }
    }

    func addApplicationExclusion(_ bundleIdentifier: String) {
        performUpdate {
            try await self.controller.appendApplicationExclusion(
                bundleIdentifier: bundleIdentifier,
                ruleID: "app-\(UUID().uuidString.lowercased())"
            )
        }
    }

    func addSiteExclusion(_ host: String, includeSubdomains: Bool) {
        performUpdate {
            try await self.controller.appendSiteExclusion(
                host: host,
                includeSubdomains: includeSubdomains,
                ruleID: "site-\(UUID().uuidString.lowercased())"
            )
        }
    }

    func moveRule(id: String, to destinationIndex: Int) {
        performUpdate {
            try await self.controller.moveRule(id: id, to: destinationIndex)
        }
    }

    func removeRule(id: String) {
        performUpdate {
            try await self.controller.removeRule(id: id)
        }
    }

    func setPrivateBrowserHandling(_ handling: PrivateBrowserHandling) {
        performUpdate {
            try await self.controller.replacePrivateBrowserHandling(handling)
        }
    }

    func refreshPermissionHealth() {
        Task {
            permissionHealth = await permissionHealthMonitor.refresh()
        }
    }

    func testContext(bundleIdentifier: String, host: String) {
        Task {
            do {
                let context = try Self.context(
                    bundleIdentifier: bundleIdentifier,
                    host: host
                )
                preview = try await controller.preview(context: context)
                statusMessage = nil
            } catch {
                preview = nil
                statusMessage = "Enter a valid application identifier and optional host."
            }
        }
    }

    private func performUpdate(
        _ operation: @escaping @MainActor () async throws -> PrivacyPolicyUpdateReceipt
    ) {
        Task {
            do {
                let receipt = try await operation()
                snapshot = PrivacyPolicySettingsSnapshot(
                    configuration: receipt.configuration,
                    policyGeneration: receipt.policyGeneration
                )
                preview = nil
                statusMessage = "Privacy rules applied immediately."
                loadState = .ready
            } catch {
                statusMessage = "Privacy rule was not changed. Check the value and try again."
            }
        }
    }

    private static func context(
        bundleIdentifier: String,
        host: String
    ) throws -> PrivacyEvaluationContext {
        let normalizedBundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBundle.isEmpty else {
            throw PrivacyPolicySettingsError.invalidApplicationIdentifier(bundleIdentifier)
        }
        let targetWindowID: UInt32 = 56
        let browserContext: BrowserContextResolution?
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHost.isEmpty {
            browserContext = nil
        } else {
            let origin = try BrowserOrigin(
                scheme: "https",
                host: normalizedHost,
                path: "/preview"
            )
            let family: BrowserFamily
            switch normalizedBundle {
            case "com.apple.Safari": family = .safari
            case "com.microsoft.edgemac": family = .edge
            case "org.mozilla.firefox": family = .firefox
            default: family = .chrome
            }
            let context = try BrowserContext(
                family: family,
                origin: origin,
                isPrivateContext: false
            )
            browserContext = .approved(
                ApprovedBrowserContextOutput(
                    targetWindowID: targetWindowID,
                    context: context,
                    serializedURL: "https" + "://\(origin.host)/preview"
                )
            )
        }
        return PrivacyEvaluationContext(
            targetWindowID: targetWindowID,
            processID: 560,
            bundleIdentifier: normalizedBundle,
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: browserContext,
            captureEpochID: UUID(uuidString: "00000000-0000-0000-0000-000000000056")
        )
    }
}

struct PrivacySettingsPane: View {
    @ObservedObject var model: PrivacySettingsViewModel
    @State private var applicationIdentifier = ""
    @State private var siteHost = ""
    @State private var includesSubdomains = true
    @State private var previewApplicationIdentifier = "com.example.private-notes"
    @State private var previewHost = ""

    private var rules: [PrivacyRule] {
        model.snapshot?.configuration.rules ?? []
    }

    var body: some View {
        Form {
            Section("Fixed protections") {
                LabeledContent("Capture surface", value: "Foreground window only")
                LabeledContent("Private windows", value: "Excluded by default")
                Text("Fixed system and Local Memory exclusions always take precedence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Browser and permission health") {
                Picker(
                    "Private browser windows",
                    selection: Binding(
                        get: {
                            model.snapshot?.configuration.privateBrowserHandling ?? .exclude
                        },
                        set: { model.setPrivateBrowserHandling($0) }
                    )
                ) {
                    Text("Exclude").tag(PrivateBrowserHandling.exclude)
                    Text("Allow only without site rules").tag(PrivateBrowserHandling.allow)
                }
                .accessibilityIdentifier("privacy.privateBrowserHandling")

                LabeledContent(
                    "Screen Recording",
                    value: permissionLabel(model.permissionHealth?.screenRecording)
                )
                LabeledContent(
                    "Accessibility",
                    value: permissionLabel(model.permissionHealth?.accessibility)
                )
                Button("Refresh Permission Health") {
                    model.refreshPermissionHealth()
                }
                .accessibilityIdentifier("privacy.refreshPermissionHealth")

                if let reason = model.permissionHealth?.recordingUserVisibleReason
                    ?? model.permissionHealth?.protectedBrowserUserVisibleReason
                {
                    Label(reason, systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("privacy.browserProtectionReason")
                } else {
                    Label("Protected browser context is available", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.browserProtectionHealthy")
                }

                Text(
                    "Browser capture pauses whenever a protected URL, private-window state, adapter version, or required permission cannot be verified."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Application exclusions") {
                HStack {
                    TextField("Bundle identifier", text: $applicationIdentifier)
                        .accessibilityIdentifier("privacy.applicationField")
                    Button("Exclude") {
                        model.addApplicationExclusion(applicationIdentifier)
                        applicationIdentifier = ""
                    }
                    .disabled(
                        applicationIdentifier.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                    .accessibilityIdentifier("privacy.addApplication")
                }
                Text("Example: com.example.private-notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Site exclusions") {
                HStack {
                    TextField("Host", text: $siteHost)
                        .accessibilityIdentifier("privacy.siteField")
                    Toggle("Include subdomains", isOn: $includesSubdomains)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("privacy.siteSubdomains")
                    Button("Exclude") {
                        model.addSiteExclusion(siteHost, includeSubdomains: includesSubdomains)
                        siteHost = ""
                    }
                    .disabled(siteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("privacy.addSite")
                }
            }

            Section("Ordered user rules") {
                Text(
                    "Rules are evaluated in order. The last matching user rule wins; fixed protections still take precedence."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("privacy.orderExplanation")

                if rules.isEmpty {
                    ContentUnavailableView(
                        "No custom exclusions",
                        systemImage: "hand.raised.slash",
                        description: Text("Add an application or site above.")
                    )
                    .accessibilityIdentifier("privacy.emptyRules")
                } else {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        PrivacyRuleRow(
                            model: rowModel(rule: rule, index: index),
                            canMoveUp: index > 0,
                            canMoveDown: index < rules.count - 1,
                            moveUp: { model.moveRule(id: rule.id, to: index - 1) },
                            moveDown: { model.moveRule(id: rule.id, to: index + 1) },
                            remove: { model.removeRule(id: rule.id) }
                        )
                    }
                }
            }

            Section("Test this context") {
                TextField("Application bundle identifier", text: $previewApplicationIdentifier)
                    .accessibilityIdentifier("privacy.previewApplication")
                TextField("Optional browser host", text: $previewHost)
                    .accessibilityIdentifier("privacy.previewHost")
                Button("Test Context") {
                    model.testContext(
                        bundleIdentifier: previewApplicationIdentifier,
                        host: previewHost
                    )
                }
                .accessibilityIdentifier("privacy.testContext")

                if let preview = model.preview {
                    Label(
                        preview.isAllowed ? "Capture allowed" : "Capture blocked",
                        systemImage: preview.isAllowed ? "checkmark.circle" : "hand.raised.fill"
                    )
                    .accessibilityIdentifier("privacy.previewResult")
                    Text(preview.visibleRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.previewRule")
                }
            }

            if let statusMessage = model.statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.callout)
                        .accessibilityIdentifier("privacy.status")
                }
            }

            if case .failure(let diagnosticCode) = model.loadState {
                Section {
                    InlineErrorView(
                        message: "Privacy settings could not be loaded",
                        diagnosticCode: diagnosticCode,
                        retryTitle: "Try Again"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(MemoryColorToken.surfaceWindow.color)
        .task { await model.load() }
        .accessibilityIdentifier("privacy.settingsPane")
    }

    private func rowModel(rule: PrivacyRule, index: Int) -> PrivacyRuleRowModel {
        let title: String
        let detail: String
        switch rule.matcher {
        case .application(let bundleIdentifier):
            title = "\(rule.action == .deny ? "Block" : "Allow") \(bundleIdentifier)"
            detail = "Application · Last matching user rule wins"
        case .hostExact(let host):
            title = "\(rule.action == .deny ? "Block" : "Allow") \(host)"
            detail = "Exact site · Last matching user rule wins"
        case .hostSuffix(let host):
            title = "\(rule.action == .deny ? "Block" : "Allow") \(host) and subdomains"
            detail = "Site suffix · Last matching user rule wins"
        }
        return PrivacyRuleRowModel(
            id: rule.id,
            title: title,
            detail: detail,
            precedence: index + 1,
            actionLabel: rule.action == .deny ? "Blocked" : "Allowed"
        )
    }

    private func permissionLabel(_ state: CapturePermissionHealthState?) -> String {
        switch state {
        case .granted: "Granted"
        case .denied: "Required"
        case .revoked: "Revoked"
        case nil: "Checking"
        }
    }
}
