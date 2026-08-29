import Foundation
import MemoryAgentAccess
import MemoryContracts
import MemoryStore
import SwiftUI

@MainActor
final class AgentAccessSettingsViewModel: ObservableObject {
    @Published var policyName = ""
    @Published var bundleIdentifiers = ""
    @Published var hosts = ""
    @Published var historyWindow: AgentAccessHistoryWindow = .lastTwentyFourHours
    @Published var sessionDuration: AgentAccessSessionDuration = .oneHour
    @Published var allowImages = false
    @Published var maxResults = 20
    @Published private(set) var review: AgentAccessPolicyReview?
    @Published private(set) var policies: [AccessPolicy] = []
    @Published private(set) var auditRows: [ArchiveAgentAccessAuditRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    let diagnostics: AgentHelperDiagnostics

    private let database: ArchiveDatabase?
    private let policyStore: AccessPolicyStore?

    init(
        database: ArchiveDatabase?,
        applicationExecutableURL: URL? = Bundle.main.executableURL,
        performsInitialLoad: Bool = true
    ) {
        self.database = database
        if let root = database?.paths?.root {
            policyStore = AccessPolicyStore(
                fileURL: root.appending(path: "agent-access/policies-v1.json")
            )
        } else {
            policyStore = nil
        }
        let executable =
            applicationExecutableURL
            ?? URL(fileURLWithPath: "/Applications/Local Memory.app/Contents/MacOS/Local Memory")
        diagnostics = AgentHelperDiagnostics.inspect(applicationExecutableURL: executable)
        if performsInitialLoad { reload() }
    }

    static var preview: AgentAccessSettingsViewModel {
        let model = AgentAccessSettingsViewModel(
            database: nil,
            applicationExecutableURL: URL(
                fileURLWithPath: "/Applications/Local Memory.app/Contents/MacOS/Local Memory"
            ),
            performsInitialLoad: false
        )
        model.errorMessage = "Preview: local archive is unavailable."
        return model
    }

    var canReview: Bool {
        !policyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    func reviewScope(now: Date = Date()) {
        do {
            review = try AgentAccessPolicyProposal(
                name: policyName.trimmingCharacters(in: .whitespacesAndNewlines),
                historyWindow: historyWindow,
                allowedBundleIDs: Self.list(bundleIdentifiers, lowercased: false),
                allowedHosts: Self.list(hosts, lowercased: true),
                allowImageResources: allowImages,
                maxResults: maxResults,
                sessionDuration: sessionDuration
            ).review(now: now)
            errorMessage = nil
        } catch {
            review = nil
            errorMessage = "Review the name, application identifiers, sites, and limits."
        }
    }

    func editScope() {
        review = nil
    }

    func approveReviewedScope() {
        guard let review, let policyStore, let database else {
            errorMessage = "The local policy store is unavailable."
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let approved = try review.approve(confirmationToken: review.confirmationToken)
                let policy = try await policyStore.create(approved)
                try database.registerAgentAccessPolicy(policy)
                self.review = nil
                policyName = ""
                try await load(policyStore: policyStore, database: database)
                errorMessage = nil
            } catch {
                errorMessage = "The reviewed policy could not be saved. No access was granted."
            }
        }
    }

    func revoke(_ policy: AccessPolicy) {
        guard let policyStore, let database else {
            errorMessage = "The local policy store is unavailable."
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let capability = try await policyStore.localCapability()
                try await policyStore.revoke(id: policy.id, capability: capability)
                try await load(policyStore: policyStore, database: database)
                errorMessage = nil
            } catch {
                errorMessage = "The policy could not be revoked."
            }
        }
    }

    func clearAudit() {
        guard let database else {
            errorMessage = "The local audit store is unavailable."
            return
        }
        do {
            try database.clearAgentAccessAudit()
            auditRows = []
            errorMessage = nil
        } catch {
            errorMessage = "Agent-access history could not be cleared."
        }
    }

    func reload() {
        guard let policyStore, let database else { return }
        Task {
            do {
                try await load(policyStore: policyStore, database: database)
                errorMessage = nil
            } catch {
                errorMessage = "Agent Access settings are unavailable."
            }
        }
    }

    private func load(policyStore: AccessPolicyStore, database: ArchiveDatabase) async throws {
        let capability = try await policyStore.localCapability()
        policies = try await policyStore.list(capability: capability)
        auditRows = try database.agentAccessAudit(limit: 100)
    }

    private static func list(_ value: String, lowercased: Bool) -> Set<String> {
        Set(
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { lowercased ? $0.lowercased() : $0 }
        )
    }
}

struct AgentAccessSettingsPane: View {
    @ObservedObject var model: AgentAccessSettingsViewModel

    var body: some View {
        Form {
            Label("Agent Access", systemImage: "terminal")
                .font(.title2)
                .accessibilityIdentifier("agents.title")

            Section("How access works") {
                Text(
                    "Every policy is limited by time, applications or sites, result count, and expiry. Empty application and site lists expose no content. Forever and unrestricted access are not available."
                )
                .foregroundStyle(.secondary)
            }

            Section("Create a bounded policy") {
                TextField("Policy name", text: $model.policyName)
                    .accessibilityIdentifier("agents.policy.name")
                TextField(
                    "Application bundle IDs, comma-separated",
                    text: $model.bundleIdentifiers
                )
                .accessibilityIdentifier("agents.policy.applications")
                TextField("Site hosts, comma-separated", text: $model.hosts)
                    .accessibilityIdentifier("agents.policy.hosts")
                Picker("History", selection: $model.historyWindow) {
                    Text("Last 24 hours").tag(AgentAccessHistoryWindow.lastTwentyFourHours)
                    Text("Last 7 days").tag(AgentAccessHistoryWindow.lastSevenDays)
                    Text("Last 30 days").tag(AgentAccessHistoryWindow.lastThirtyDays)
                }
                Picker("Expires after", selection: $model.sessionDuration) {
                    Text("1 hour").tag(AgentAccessSessionDuration.oneHour)
                    Text("8 hours").tag(AgentAccessSessionDuration.eightHours)
                    Text("24 hours").tag(AgentAccessSessionDuration.twentyFourHours)
                }
                Stepper(
                    "Maximum results: \(model.maxResults)", value: $model.maxResults, in: 1...100)
                Toggle("Allow separately requested moment images", isOn: $model.allowImages)
                Button("Review exact scope") { model.reviewScope() }
                    .disabled(!model.canReview)
                    .accessibilityIdentifier("agents.policy.review")
            }

            if let review = model.review {
                Section("Review before approving") {
                    Text(review.explanation)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agents.policy.explanation")
                    HStack {
                        Button("Edit") { model.editScope() }
                        Button("Approve this scope") { model.approveReviewedScope() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("agents.policy.approve")
                    }
                }
            }

            Section("Approved policies") {
                if model.policies.isEmpty {
                    Text("No active policies")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.policies, id: \.id) { policy in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(policy.name).font(.headline)
                            Spacer()
                            Button("Revoke", role: .destructive) { model.revoke(policy) }
                        }
                        Text(policySummary(policy))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Helper diagnostics") {
                LabeledContent("Signed application", value: model.diagnostics.state.rawValue)
                Text(model.diagnostics.applicationExecutablePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("MCP uses local standard input/output and opens no listening socket.")
                    .foregroundStyle(.secondary)
                Text(model.diagnostics.mcpConfiguration)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("MCP client configuration")
            }

            Section("Local content-free audit") {
                HStack {
                    Text(
                        "Queries are stored only as SHA-256 hashes, never as query text or captured content."
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear history", role: .destructive) { model.clearAudit() }
                        .disabled(model.auditRows.isEmpty)
                }
                if model.auditRows.isEmpty {
                    Text("No agent access recorded")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.auditRows, id: \.id) { row in
                    LabeledContent(
                        "\(row.actor.rawValue) · \(row.action)",
                        value: "\(row.resultCount) results"
                    )
                }
            }

            if let errorMessage = model.errorMessage {
                Section("Status") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("agents.error")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }

    private func policySummary(_ policy: AccessPolicy) -> String {
        let apps =
            policy.allowedBundleIDs.isEmpty ? "no apps" : "\(policy.allowedBundleIDs.count) apps"
        let sites = policy.allowedHosts.isEmpty ? "no sites" : "\(policy.allowedHosts.count) sites"
        let images = policy.allowImageResources ? "images allowed" : "text only"
        return
            "\(apps), \(sites), \(images), max \(policy.maxResults); expires \(policy.expiresAt.formatted())"
    }
}

#Preview("Agent Access unavailable") {
    AgentAccessSettingsPane(model: .preview)
        .frame(width: 760, height: 720)
}
