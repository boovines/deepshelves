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
            } else if let selectedResult = model.selectedResult {
                SearchMomentDetailView(
                    result: selectedResult,
                    navigationModel: navigationModel,
                    searchModel: searchModel,
                    repository: searchModel.momentDetailRepository,
                    exportProvider: searchModel.momentExportProvider,
                    timelineLoader: searchModel.momentTimelineLoader,
                    thumbnailRepository: searchModel.thumbnailRepository
                )
                .id(selectedResult.frameID)
            } else {
                ContentUnavailableView(
                    "Choose a moment",
                    systemImage: "rectangle.stack.badge.clock",
                    description: Text("Select a recorded moment from the timeline rail.")
                )
            }
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

}

private enum TimelineForgetPresentationError: Error {
    case unavailable
}
