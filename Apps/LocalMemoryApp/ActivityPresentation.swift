import Foundation
import MemoryContracts
import MemoryDesignSystem
import MemoryStore
import SwiftUI

enum ActivityRangeMode: String, CaseIterable {
    case day
    case week
}

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var rangeMode: ActivityRangeMode = .week
    @Published var anchor = Date()
    @Published private(set) var projection: ActivityHeatmapProjection?
    @Published private(set) var summary: ActivitySummaryProjection?
    @Published private(set) var isLoading = false
    @Published private(set) var errorCode: String?

    private let store: ArchiveForegroundActivityStore?
    private let calendar: Calendar
    private let usesFixtureData: Bool
    private var generation = 0

    init(
        database: ArchiveDatabase?,
        calendar: Calendar = .autoupdatingCurrent,
        usesFixtureData: Bool = false
    ) {
        store = database.map(ArchiveForegroundActivityStore.init(database:))
        self.calendar = calendar
        self.usesFixtureData = usesFixtureData
    }

    func reload() {
        generation += 1
        let requestedGeneration = generation
        guard let interval = selectedInterval else {
            projection = nil
            summary = nil
            errorCode = "LM-ACTIVITY-CALENDAR"
            return
        }
        let store = store
        let calendar = calendar
        let fixtureRecords =
            usesFixtureData ? Self.fixtureRecords(in: interval, calendar: calendar) : nil
        isLoading = true
        Task {
            do {
                let projected = try await Task.detached {
                    let records = try fixtureRecords ?? store?.intervals(in: interval) ?? []
                    return try (
                        heatmap: ActivityHeatmapProjector.project(
                            records: records,
                            interval: interval,
                            calendar: calendar
                        ),
                        summary: ActivitySummaryProjector.project(
                            records: records,
                            interval: interval
                        )
                    )
                }.value
                guard requestedGeneration == generation else { return }
                projection = projected.heatmap
                summary = projected.summary
                errorCode = nil
                isLoading = false
            } catch {
                guard requestedGeneration == generation else { return }
                projection = nil
                summary = nil
                errorCode = "LM-ACTIVITY-LOAD"
                isLoading = false
            }
        }
    }

    nonisolated private static func fixtureRecords(
        in interval: DateInterval,
        calendar: Calendar
    ) -> [DurableForegroundActivityInterval]? {
        let browser = ApprovedForegroundActivityIdentity(
            bundleID: "com.apple.Safari",
            applicationName: "Safari"
        )
        let notes = ApprovedForegroundActivityIdentity(
            bundleID: "com.apple.Notes",
            applicationName: "Notes"
        )
        let calendarApp = ApprovedForegroundActivityIdentity(
            bundleID: "com.apple.Calendar",
            applicationName: "Calendar"
        )
        var observations = [
            ForegroundActivityObservation(
                occurredAt: interval.start,
                activity: .idle,
                identity: nil,
                gapReason: .idle
            )
        ]
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let schedule:
                [(
                    Int, Int, ActivityState, ApprovedForegroundActivityIdentity?,
                    RecordingGapReason?
                )] = [
                    (8, 20, .active, browser, nil),
                    (9, 35, .idle, browser, .idle),
                    (10, 5, .active, notes, nil),
                    (11, 45, .idle, notes, .idle),
                    (13, 10, .active, calendarApp, nil),
                    (14, 25, .active, browser, nil),
                    (16, 40, .idle, browser, .idle),
                ]
            for (hour, minute, state, identity, reason) in schedule {
                guard
                    let occurredAt = calendar.date(
                        bySettingHour: hour,
                        minute: minute,
                        second: 0,
                        of: day
                    ), interval.contains(occurredAt)
                else { continue }
                observations.append(
                    ForegroundActivityObservation(
                        occurredAt: occurredAt,
                        activity: state,
                        identity: identity,
                        gapReason: reason
                    )
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        observations.sort { $0.occurredAt < $1.occurredAt }
        return try? ForegroundActivityDeriver.derive(
            observations: observations,
            through: interval.end
        )
    }

    var selectedInterval: DateInterval? {
        switch rangeMode {
        case .day:
            calendar.dateInterval(of: .day, for: anchor)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: anchor)
        }
    }
}

struct ActivityShellView: View {
    @ObservedObject var model: ActivityViewModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    let localizationMode: ShellLocalizationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            Text(ActivitySummaryProjection.explanatoryText)
                .foregroundStyle(.secondary)

            if model.isLoading {
                ProgressView("Loading local activity…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorCode = model.errorCode {
                ContentUnavailableView(
                    "Activity unavailable",
                    systemImage: "exclamationmark.circle",
                    description: Text("Local activity could not be loaded. \(errorCode)")
                )
            } else if let projection = model.projection {
                if let summary = model.summary {
                    summaryPanel(summary)
                }
                heatmap(projection)
                    .accessibilityRepresentation {
                        accessibilityRows(projection)
                    }
            } else {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Recorded foreground time will appear here.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .task { model.reload() }
        .accessibilityIdentifier("activity.section")
    }

    private func summaryPanel(_ summary: ActivitySummaryProjection) -> some View {
        GroupBox("Activity estimates") {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.applications) { application in
                            HStack {
                                Text(application.applicationName)
                                Spacer()
                                Text(application.durationLabel)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(application.accessibilityLabel)
                        }
                    }
                }
                .frame(maxHeight: 160)
                Divider()
                HStack {
                    Text("Unrecorded")
                    Spacer()
                    Text(summary.unrecordedDurationLabel)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.unrecordedAccessibilityLabel)
            }
        }
        .accessibilityIdentifier("activity.summary")
    }

    private var header: some View {
        HStack {
            Label(localizationMode.localized("Activity"), systemImage: "chart.xyaxis.line")
                .font(.title2)
                .accessibilityIdentifier("main.sectionTitle")
            Spacer()
            if let interval = model.selectedInterval {
                Text(interval.start.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Activity range", selection: $model.rangeMode) {
                Text("Day").tag(ActivityRangeMode.day)
                Text("Week").tag(ActivityRangeMode.week)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .onChange(of: model.rangeMode) { _, _ in model.reload() }

            DatePicker("Activity date", selection: $model.anchor, displayedComponents: .date)
                .labelsHidden()
                .onChange(of: model.anchor) { _, _ in model.reload() }
                .accessibilityIdentifier("activity.datePicker")
            Spacer()
        }
    }

    private func heatmap(_ projection: ActivityHeatmapProjection) -> some View {
        GroupBox("Recorded active minutes by local hour") {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(projection.days) { day in
                        HStack(spacing: 3) {
                            Text(day.label)
                                .font(.caption)
                                .frame(width: 84, alignment: .trailing)
                            ForEach(day.cells) { cell in
                                Button {
                                    if let interval = cell.timelineInterval {
                                        navigationModel.openTimeline(interval: interval)
                                    }
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(
                                                cell.occurrence == .missing
                                                    ? MemoryColorToken.surfaceControl.color
                                                    : MemoryColorToken.accent.color.opacity(
                                                        0.12 + 0.88 * cell.intensity
                                                    )
                                            )
                                        if cell.occurrence == .missing {
                                            Image(systemName: "minus")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 27, height: 27)
                                }
                                .buttonStyle(.plain)
                                .disabled(cell.timelineInterval == nil)
                                .help(cell.accessibilityLabel)
                                .accessibilityLabel(cell.accessibilityLabel)
                                .accessibilityIdentifier("activity.cell.\(cell.id)")
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("activity.heatmap")
    }

    private func accessibilityRows(_ projection: ActivityHeatmapProjection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity accessibility table")
            ForEach(projection.days) { day in
                let label = day.tableRows.map(\.accessibilityLabel).joined(separator: "; ")
                Text(label)
                    .accessibilityLabel(label)
            }
        }
        .accessibilityIdentifier("activity.accessibilityTable")
    }
}
