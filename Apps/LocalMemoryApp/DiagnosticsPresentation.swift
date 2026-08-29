import AppKit
import Darwin
import Foundation
import MemoryStore
import SwiftUI

@MainActor
final class LocalDiagnosticsViewModel: ObservableObject {
    @Published private(set) var snapshot: LocalDiagnosticsSnapshot?
    @Published private(set) var health: LocalDiagnosticsHealthProjection?
    @Published private(set) var isLoading = false
    @Published private(set) var errorCode: String?
    @Published private(set) var exportPreview: LocalDiagnosticExportPreview?
    @Published private(set) var exportedBundleURL: URL?

    let logger: ContentFreeDiagnosticLogger?
    let signposter = LocalPerformanceSignposter()

    private let database: ArchiveDatabase?
    private let exportDirectory: URL?
    private var generation = 0

    init(database: ArchiveDatabase?) {
        self.database = database
        exportDirectory = database?.paths?.exports
        logger = database?.paths.flatMap { paths in
            try? ContentFreeDiagnosticLogger(directory: paths.logs)
        }
    }

    func refresh() {
        generation += 1
        let requestedGeneration = generation
        guard let database else {
            snapshot = nil
            health = nil
            errorCode = "LM-DIAGNOSTICS-ARCHIVE"
            return
        }
        isLoading = true
        let logger = logger
        Task {
            do {
                let measured = try await Task.detached {
                    try Self.collect(database: database)
                }.value
                if let logger {
                    try logger.append(
                        LocalDiagnosticRecord(
                            occurredAt: measured.measuredAt,
                            event: .resourceSample,
                            state: nil,
                            captureID: nil,
                            errorCode: measured.lastErrorCode,
                            metrics: [
                                .residentMemoryBytes: Double(measured.residentMemoryBytes),
                                .databaseBytes: Double(measured.databaseBytes),
                                .mediaBytes: Double(measured.mediaBytes),
                                .logBytes: Double(measured.logBytes),
                                .pendingIndexJobs: Double(measured.pendingIndexJobs),
                            ]
                        )
                    )
                }
                guard requestedGeneration == generation else { return }
                snapshot = measured
                health = LocalDiagnosticsHealthProjection(snapshot: measured)
                errorCode = nil
                isLoading = false
            } catch {
                guard requestedGeneration == generation else { return }
                snapshot = nil
                health = nil
                errorCode = "LM-DIAGNOSTICS-REFRESH"
                isLoading = false
            }
        }
    }

    func createExport() {
        guard let logger, let snapshot, let exportDirectory else {
            errorCode = "LM-DIAGNOSTICS-EXPORT"
            return
        }
        do {
            let result = try signposter.measure(.diagnosticExport) {
                try LocalDiagnosticExporter.export(
                    logger: logger,
                    snapshot: snapshot,
                    destinationDirectory: exportDirectory
                )
            }
            exportPreview = result.preview
            exportedBundleURL = result.bundleURL
            errorCode = nil
        } catch {
            exportPreview = nil
            exportedBundleURL = nil
            errorCode = "LM-DIAGNOSTICS-EXPORT"
        }
    }

    func revealExport() {
        guard let exportedBundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedBundleURL])
    }

    private nonisolated static func collect(
        database: ArchiveDatabase,
        fileManager: FileManager = .default
    ) throws -> LocalDiagnosticsSnapshot {
        guard let paths = database.paths else {
            throw LocalDiagnosticsError.invalidSnapshot
        }
        let databaseBytes = try allocatedBytes(in: paths.database, fileManager: fileManager)
        let logBytes = try allocatedBytes(in: paths.logs, fileManager: fileManager)
        let rootBytes = try allocatedBytes(in: paths.root, fileManager: fileManager)
        let backlog = try ArchiveEnrichmentJobStore(database: database).backlog(now: Date())
        return try LocalDiagnosticsSnapshot(
            measuredAt: backlog.measuredAt,
            energyCondition: energyCondition,
            residentMemoryBytes: try residentMemoryBytes(),
            databaseBytes: databaseBytes,
            mediaBytes: max(0, rootBytes - databaseBytes - logBytes),
            logBytes: logBytes,
            projectedMonthlyStorageBytes: nil,
            pendingIndexJobs: backlog.totalPending,
            lastErrorCode: backlog.permanentFailures > 0 ? "LM-INDEX-PERMANENT" : nil
        )
    }

    private nonisolated static var energyCondition: LocalEnergyCondition {
        let process = ProcessInfo.processInfo
        switch process.thermalState {
        case .nominal:
            return process.isLowPowerModeEnabled ? .elevated : .nominal
        case .fair:
            return .elevated
        case .serious, .critical:
            return .constrained
        @unknown default:
            return .unavailable
        }
    }

    private nonisolated static func residentMemoryBytes() throws -> Int64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { throw LocalDiagnosticsError.invalidSnapshot }
        return Int64(information.resident_size)
    }

    private nonisolated static func allocatedBytes(
        in root: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += Int64(
                values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            )
        }
        return total
    }
}

struct LocalDiagnosticsSettingsPane: View {
    @ObservedObject var model: LocalDiagnosticsViewModel
    @ObservedObject var lifecycleModel: AppLifecycleViewModel

    var body: some View {
        Form {
            Label("About & Diagnostics", systemImage: "info.circle")
                .font(.title2)
                .accessibilityIdentifier("settings.title")
            Section("Local observability") {
                LabeledContent("Capture", value: lifecycleModel.menuProjection.statusLabel)
                if let snapshot = model.snapshot, let health = model.health {
                    diagnosticRow("Energy", value: snapshot.energyCondition.rawValue, health.energy)
                    diagnosticRow(
                        "Resident memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: snapshot.residentMemoryBytes,
                            countStyle: .memory
                        ),
                        health.memory
                    )
                    diagnosticRow(
                        "Local storage",
                        value: ByteCountFormatter.string(
                            fromByteCount: snapshot.totalStorageBytes,
                            countStyle: .file
                        ),
                        health.storage
                    )
                    LabeledContent("Monthly growth", value: "Collecting local baseline")
                    diagnosticRow(
                        "Index backlog",
                        value: "\(snapshot.pendingIndexJobs) pending",
                        health.indexBacklog
                    )
                    if let errorCode = snapshot.lastErrorCode {
                        LabeledContent("Last error", value: errorCode)
                    }
                } else if model.isLoading {
                    ProgressView("Reading local metrics…")
                } else {
                    Text("Local metrics are unavailable.")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh Local Metrics", action: model.refresh)
                    .accessibilityIdentifier("diagnostics.refresh")
            }

            Section("Content-free logs") {
                Text(
                    "Logs are local, owner-only, and bounded to three 1 MB files. They contain typed states, counts, durations, identifiers, and error codes—not captured pixels, extracted text, window titles, URLs, queries, or agent results."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Create Local Diagnostic Bundle", action: model.createExport)
                    .disabled(model.snapshot == nil)
                    .accessibilityIdentifier("diagnostics.export")
                if let preview = model.exportPreview {
                    LabeledContent("Export records", value: "\(preview.recordCount)")
                    LabeledContent("Files", value: preview.files.joined(separator: ", "))
                    LabeledContent(
                        "Captured content",
                        value: preview.includesCapturedContent ? "Included" : "Not included"
                    )
                    Button("Reveal Diagnostic Bundle", action: model.revealExport)
                }
            }
            if let errorCode = model.errorCode {
                Section("Diagnostic status") {
                    LabeledContent("Error code", value: errorCode)
                }
            }
        }
        .formStyle(.grouped)
        .task { model.refresh() }
        .accessibilityIdentifier("diagnostics.root")
    }

    private func diagnosticRow(
        _ title: String,
        value: String,
        _ health: LocalDiagnosticsHealthLevel
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value)
                Text(health.rawValue.capitalized)
                    .foregroundStyle(health == .normal ? Color.secondary : Color.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(health.rawValue)")
    }
}
