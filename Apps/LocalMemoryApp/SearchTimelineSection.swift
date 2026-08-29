import MemoryContracts
import MemoryDesignSystem
import MemorySearch
import SwiftUI

struct SearchTimelineSectionView: View {
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    let revisitProvider: MomentRevisitProvider?

    @StateObject private var model: TimelineSectionSessionModel
    @StateObject private var forgetModel: ForgetSessionModel
    @State private var revisitStatus: String?
    @State private var showsForgetConfirmation = false

    init(
        navigationModel: MainNavigationViewModel,
        searchModel: SearchSessionModel,
        loader: MomentTimelinePageLoader?,
        revisitProvider: MomentRevisitProvider?
    ) {
        self.navigationModel = navigationModel
        self.searchModel = searchModel
        self.revisitProvider = revisitProvider
        let loader =
            loader
            ?? MomentTimelinePageLoader { _ in
                throw MomentTimelineError.unavailable
            }
        _model = StateObject(wrappedValue: TimelineSectionSessionModel(loader: loader))
        let unavailableProvider = MomentForgetProvider { _ in
            throw TimelineForgetPresentationError.unavailable
        }
        _forgetModel = StateObject(
            wrappedValue: ForgetSessionModel(
                provider: searchModel.momentForgetProvider ?? unavailableProvider
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            content
            if let revisitStatus {
                Text(revisitStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("timeline.revisitStatus")
            }
        }
        .padding()
        .task(id: navigationModel.isRestored) {
            guard navigationModel.isRestored else { return }
            if let interval = navigationModel.takeTimelineDrillThroughInterval() {
                await model.focus(interval: interval)
            } else {
                await model.load(date: navigationModel.snapshot.timelineDate ?? Date())
            }
            navigationModel.selectTimelineDate(model.day.anchor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellRevisit)) { _ in
            if let result = model.selectedResult { revisit(result) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellForgetMoment)) { _ in
            if let result = model.selectedResult {
                beginForget(.moment(result.frameID))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellPreviousTransition)) { _ in
            model.selectAdjacentApplicationTransition(.previous)
            if let result = model.selectedResult {
                navigationModel.select(momentID: result.frameID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellNextTransition)) { _ in
            model.selectAdjacentApplicationTransition(.next)
            if let result = model.selectedResult {
                navigationModel.select(momentID: result.frameID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellPreviousDay)) { _ in
            moveDay(-1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellNextDay)) { _ in
            moveDay(1)
        }
        .onDisappear { model.clear() }
        .sheet(isPresented: $showsForgetConfirmation) {
            ForgetConfirmationFlow(
                model: forgetModel,
                onHidden: hideForgottenResults,
                onDismiss: { showsForgetConfirmation = false }
            )
        }
        .accessibilityIdentifier("timeline.section")
    }

    private var header: some View {
        HStack {
            Label("Timeline", systemImage: "clock.arrow.circlepath")
                .font(.title2)
            Spacer()
            Text(model.day.anchor.formatted(date: .long, time: .omitted))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("timeline.selectedDateLabel")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Previous day", systemImage: "chevron.left") {
                moveDay(-1)
            }
            .labelStyle(.iconOnly)
            .help("Previous day")
            .accessibilityIdentifier("timeline.previousDay")

            DatePicker(
                "Timeline date",
                selection: dateBinding,
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityIdentifier("timeline.datePicker")

            Button("Next day", systemImage: "chevron.right") {
                moveDay(1)
            }
            .labelStyle(.iconOnly)
            .help("Next day")
            .accessibilityIdentifier("timeline.nextDay")

            Button("Jump to today") {
                Task {
                    await model.jumpToToday()
                    navigationModel.selectTimelineDate(model.day.anchor)
                }
            }
            .accessibilityIdentifier("timeline.today")

            Spacer()

            Picker("Timeline zoom", selection: zoomBinding) {
                Text("Day").tag(MomentTimelineZoomLevel.calendarDay)
                Text("6 hours").tag(MomentTimelineZoomLevel.sixHours)
                Text("1 hour").tag(MomentTimelineZoomLevel.oneHour)
                Text("15 minutes").tag(MomentTimelineZoomLevel.fifteenMinutes)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("timeline.sectionZoom")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Loading this day…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure:
            ContentUnavailableView(
                "Timeline unavailable",
                systemImage: "exclamationmark.circle",
                description: Text("The selected local interval could not be loaded.")
            )
        case .ready(let projection):
            if projection.moments.isEmpty {
                ContentUnavailableView(
                    "No recorded moments",
                    systemImage: "clock.badge.xmark",
                    description: Text("Gaps remain visible when recording was unavailable.")
                )
                .overlay(alignment: .bottom) { gapSummary(projection) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    filmstrip(projection)
                    transitionSummary
                    selectedContext
                }
            }
        }
    }

    private func filmstrip(_ projection: MomentTimelineProjection) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(MemoryColorToken.surfaceControl.color.opacity(0.55))

                ForEach(hourTicks(in: projection.interval), id: \.date) { tick in
                    Rectangle()
                        .fill(MemoryColorToken.borderDefault.color.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: tick.position * width)
                        .overlay(alignment: .topLeading) {
                            Text(tick.label)
                                .font(.caption2.monospacedDigit())
                                .fixedSize()
                                .offset(x: tick.position * width + 3, y: 3)
                        }
                        .accessibilityHidden(true)
                }

                ForEach(Array(projection.gaps.enumerated()), id: \.offset) { _, gap in
                    MomentTimelineGapPatternView(pattern: gap.pattern)
                        .frame(
                            width: max(2, (gap.normalizedEnd - gap.normalizedStart) * width),
                            height: 42
                        )
                        .offset(x: gap.normalizedStart * width, y: 30)
                        .accessibilityLabel(gap.accessibilityLabel)
                }

                ForEach(projection.moments, id: \.result.frameID) { moment in
                    Button {
                        model.select(frameID: moment.result.frameID)
                        navigationModel.select(momentID: moment.result.frameID)
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                model.selectedResult?.frameID == moment.result.frameID
                                    ? MemoryColorToken.accent.color
                                    : MemoryColorToken.textSecondary.color.opacity(0.65)
                            )
                            .frame(width: 8, height: 38)
                    }
                    .buttonStyle(.plain)
                    .offset(x: moment.normalizedPosition * max(0, width - 8), y: 32)
                    .accessibilityLabel(
                        "\(moment.result.capturedAt.formatted(date: .omitted, time: .standard)), "
                            + moment.result.foreground.applicationName
                    )
                }

                ForEach(model.transitions.filter { !$0.isSummary }) { transition in
                    if let position = transition.normalizedPosition {
                        Text(transition.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .offset(x: position * max(0, width - 120), y: 78)
                            .accessibilityLabel(transition.label)
                    }
                }
            }
        }
        .frame(minHeight: 116)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected day timeline")
        .accessibilityIdentifier("timeline.filmstrip")
    }

    @ViewBuilder
    private var transitionSummary: some View {
        ForEach(model.transitions.filter(\.isSummary)) { transition in
            Label(transition.label, systemImage: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedContext: some View {
        if let result = model.selectedResult {
            GroupBox("Selected moment") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.capturedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.headline)
                        Text(result.foreground.applicationName)
                        if let title = result.foreground.windowTitle { Text(title) }
                        if let host = result.browser?.origin.host {
                            Text(host).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Revisit") { revisit(result) }
                            .disabled(revisitProvider == nil)
                            .accessibilityHint(
                                "Opens only the approved application and approved address; form state is not restored"
                            )
                            .accessibilityIdentifier("timeline.revisit")
                        Button("Forget Moment…", role: .destructive) {
                            beginForget(.moment(result.frameID))
                        }
                        .disabled(searchModel.momentForgetProvider == nil)
                        .accessibilityIdentifier("timeline.forgetMoment")
                        Button("Forget This Day…", role: .destructive) {
                            beginForget(.range(model.day.interval))
                        }
                        .disabled(searchModel.momentForgetProvider == nil)
                        .accessibilityIdentifier("timeline.forgetRange")
                    }
                }
            }
            .accessibilityIdentifier("timeline.selectedContext")
        }
    }

    private func gapSummary(_ projection: MomentTimelineProjection) -> some View {
        Text(projection.gaps.map(\.accessibilityLabel).joined(separator: "; "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { model.day.anchor },
            set: { date in
                Task {
                    await model.load(date: date)
                    navigationModel.selectTimelineDate(model.day.anchor)
                }
            }
        )
    }

    private var zoomBinding: Binding<MomentTimelineZoomLevel> {
        Binding(
            get: { model.zoom },
            set: { zoom in Task { await model.setZoom(zoom) } }
        )
    }

    private func moveDay(_ offset: Int) {
        Task {
            await model.moveDay(by: offset)
            navigationModel.selectTimelineDate(model.day.anchor)
        }
    }

    private func revisit(_ result: SearchResult) {
        guard let revisitProvider else { return }
        revisitStatus = "Opening approved source…"
        Task {
            do {
                let plan = try await revisitProvider.revisit(result)
                revisitStatus =
                    plan.approvedURL == nil
                    ? "Opened approved application; no captured state was restored."
                    : "Opened approved application and address; no captured state was restored."
            } catch {
                revisitStatus = "Revisit unavailable because the current source or policy changed."
            }
        }
    }

    private func beginForget(_ target: ForgetTarget) {
        guard searchModel.momentForgetProvider != nil else { return }
        forgetModel.begin(target)
        showsForgetConfirmation = true
    }

    private func hideForgottenResults(_ frameIDs: Set<UUID>) {
        searchModel.hideResults(frameIDs: frameIDs)
        Task { await model.load(date: model.day.anchor) }
    }

    private func hourTicks(in interval: DateInterval) -> [(
        date: Date, position: Double, label: String
    )] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = Locale.autoupdatingCurrent
        var tick = calendar.dateInterval(of: .hour, for: interval.start)?.start ?? interval.start
        if tick < interval.start {
            tick = calendar.date(byAdding: .hour, value: 1, to: tick) ?? interval.start
        }
        var output: [(Date, Double, String)] = []
        while tick < interval.end, output.count < 26 {
            output.append(
                (
                    tick,
                    tick.timeIntervalSince(interval.start) / interval.duration,
                    tick.formatted(
                        Date.FormatStyle()
                            .hour(.defaultDigits(amPM: .abbreviated))
                            .timeZone(.specificName(.short))
                    )
                )
            )
            guard let next = calendar.date(byAdding: .hour, value: 1, to: tick), next > tick else {
                break
            }
            tick = next
        }
        return output
    }
}

private enum TimelineForgetPresentationError: Error {
    case unavailable
}
