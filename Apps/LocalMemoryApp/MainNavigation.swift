import AppKit
import Foundation
import MemoryContracts
import MemoryDesignSystem
import MemorySearch
import MemoryStore
import SwiftUI

enum MainWindowLaunchSize: String {
    case `default`
    case minimum

    var width: CGFloat {
        switch self {
        case .default: CGFloat(MainWindowDefaults.defaultWidth)
        case .minimum: CGFloat(MainWindowDefaults.minimumWidth)
        }
    }

    var height: CGFloat {
        switch self {
        case .default: CGFloat(MainWindowDefaults.defaultHeight)
        case .minimum: CGFloat(MainWindowDefaults.minimumHeight)
        }
    }
}

@MainActor
final class MainNavigationViewModel: ObservableObject {
    @Published private(set) var snapshot = MainNavigationSnapshot.default
    @Published private(set) var isRestored = false

    private let store: FileMainNavigationStateStore
    private var startupTask: Task<MainNavigationSnapshot?, Error>?
    private var persistenceTask: Task<Void, Never>?
    private var pendingSection: MainNavigationSection?
    private var history = MainNavigationHistory(initial: .default)

    init(stateURL: URL) {
        store = FileMainNavigationStateStore(fileURL: stateURL)
        Task { [weak self] in
            await self?.start()
        }
    }

    func start() async {
        guard !isRestored else { return }

        let task: Task<MainNavigationSnapshot?, Error>
        if let startupTask {
            task = startupTask
        } else {
            let store = store
            let createdTask = Task {
                try await store.load()
            }
            startupTask = createdTask
            task = createdTask
        }

        let restoredSnapshot: MainNavigationSnapshot
        let replacesInvalidState: Bool
        do {
            restoredSnapshot = try await task.value ?? .default
            replacesInvalidState = false
        } catch {
            restoredSnapshot = .default
            replacesInvalidState = true
        }

        guard !isRestored else { return }
        snapshot = restoredSnapshot
        history = MainNavigationHistory(initial: restoredSnapshot)
        isRestored = true

        if let pendingSection {
            self.pendingSection = nil
            select(section: pendingSection)
        } else if replacesInvalidState {
            enqueuePersistence()
        }
    }

    func select(section: MainNavigationSection) {
        guard isRestored else {
            pendingSection = section
            return
        }
        guard snapshot.section != section else { return }
        apply(
            MainNavigationSnapshot(
                section: section,
                selectedMomentID: snapshot.selectedMomentID,
                inspectorRequested: snapshot.inspectorRequested,
                timelineDate: snapshot.timelineDate
            ))
    }

    func select(momentID: UUID) {
        guard isRestored, snapshot.selectedMomentID != momentID else { return }
        apply(
            MainNavigationSnapshot(
                section: snapshot.section,
                selectedMomentID: momentID,
                inspectorRequested: snapshot.inspectorRequested,
                timelineDate: snapshot.timelineDate
            ))
    }

    func setInspectorRequested(_ requested: Bool) {
        guard isRestored, snapshot.inspectorRequested != requested else { return }
        apply(
            MainNavigationSnapshot(
                section: snapshot.section,
                selectedMomentID: snapshot.selectedMomentID,
                inspectorRequested: requested,
                timelineDate: snapshot.timelineDate
            ))
    }

    func selectTimelineDate(_ date: Date) {
        guard isRestored, snapshot.timelineDate != date else { return }
        apply(
            MainNavigationSnapshot(
                section: snapshot.section,
                selectedMomentID: snapshot.selectedMomentID,
                inspectorRequested: snapshot.inspectorRequested,
                timelineDate: date
            ))
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func goBack() {
        guard isRestored, let previous = history.goBack() else { return }
        snapshot = previous
        enqueuePersistence()
    }

    func goForward() {
        guard isRestored, let next = history.goForward() else { return }
        snapshot = next
        enqueuePersistence()
    }

    private func apply(_ newSnapshot: MainNavigationSnapshot) {
        snapshot = newSnapshot
        history.record(newSnapshot)
        enqueuePersistence()
    }

    private func enqueuePersistence() {
        let previousTask = persistenceTask
        let state = snapshot
        let store = store
        persistenceTask = Task {
            _ = await previousTask?.result
            try? await store.save(state)
        }
    }
}

private struct ShellMoment: Identifiable, Equatable {
    let id: UUID
    let accessibilitySlug: String
    let title: String
    let application: String
    let time: String
    let context: String
    let host: String
    let evidenceType: String
    let systemImage: String
}

private struct ShellTimelineGap: Identifiable, Equatable {
    let reason: RecordingGapReason
    let title: String
    let interval: String
    let systemImage: String

    var id: RecordingGapReason { reason }
    var accessibilityLabel: String { "\(title) gap, \(interval)" }
}

private enum ShellTimelineGapFixtures {
    static let gaps: [ShellTimelineGap] = [
        gap(.paused, "Paused", "9:40 AM to 9:50 AM", "pause.circle"),
        gap(.idle, "Idle", "10:15 AM to 10:30 AM", "moon.zzz"),
        gap(
            .excluded, "Excluded; no application details stored", "10:45 AM to 11:00 AM",
            "hand.raised"),
        gap(.permissionLost, "Permission lost", "11:30 AM to 11:45 AM", "exclamationmark.shield"),
        gap(
            .filterFailed, "Browser protection", "12:10 PM to 12:15 PM",
            "line.3.horizontal.decrease.circle"),
        gap(.sleep, "Mac asleep", "12:30 PM to 1:00 PM", "powersleep"),
        gap(.processStopped, "Local Memory stopped", "1:10 PM to 1:15 PM", "stop.circle"),
        gap(.unresolvedWindow, "Window unresolved", "1:20 PM to 1:25 PM", "macwindow.badge.plus"),
        gap(.ambiguousWindow, "Window ambiguous", "1:30 PM to 1:35 PM", "questionmark.square"),
        gap(.minimizedWindow, "Window minimized", "1:40 PM to 1:45 PM", "macwindow"),
        gap(
            .unsupportedDisplay, "Display unsupported", "1:50 PM to 1:55 PM",
            "display.trianglebadge.exclamationmark"),
        gap(.protectedSurface, "Protected surface", "2:00 PM to 2:05 PM", "lock.shield"),
        gap(.noWindow, "No foreground window", "2:10 PM to 2:15 PM", "rectangle.slash"),
        gap(.unknown, "Recording unavailable", "2:20 PM to 2:25 PM", "questionmark.circle"),
    ]

    private static func gap(
        _ reason: RecordingGapReason,
        _ title: String,
        _ interval: String,
        _ systemImage: String
    ) -> ShellTimelineGap {
        ShellTimelineGap(
            reason: reason,
            title: title,
            interval: interval,
            systemImage: systemImage
        )
    }
}

private enum ShellMomentFixtures {
    static let moments = [
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
            accessibilitySlug: "morning-planning",
            title: "Morning planning",
            application: "Calendar",
            time: ShellLocaleFormatting.time(
                hour: 9,
                minute: 12,
                locale: Locale(identifier: "en_US")
            ),
            context: "Local fixture · Planning window",
            host: "calendar.example.test",
            evidenceType: "Accessibility text",
            systemImage: "calendar"
        ),
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!,
            accessibilitySlug: "afternoon-research",
            title: "Afternoon research",
            application: "Safari",
            time: ShellLocaleFormatting.time(
                hour: 14,
                minute: 14,
                locale: Locale(identifier: "en_US")
            ),
            context: "example.test · Research notes",
            host: "example.test",
            evidenceType: "Visual match",
            systemImage: "safari"
        ),
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000103")!,
            accessibilitySlug: "evening-notes",
            title: "Evening notes",
            application: "Notes",
            time: ShellLocaleFormatting.time(
                hour: 17,
                minute: 42,
                locale: Locale(identifier: "en_US")
            ),
            context: "Local fixture · Daily notes",
            host: "notes.example.test",
            evidenceType: "Accessibility text",
            systemImage: "note.text"
        ),
    ]

    static func moment(id: UUID?) -> ShellMoment? {
        moments.first { $0.id == id }
    }

    static func adjacent(to id: UUID?, offset: Int) -> ShellMoment? {
        guard let id, let index = moments.firstIndex(where: { $0.id == id }) else {
            return offset >= 0 ? moments.first : moments.last
        }
        let target = min(max(index + offset, 0), moments.count - 1)
        return moments[target]
    }
}

struct MainShellView: View {
    @ObservedObject var lifecycleModel: AppLifecycleViewModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var searchFilterModel: SearchFilterSessionModel
    let forcedWindowSize: MainWindowLaunchSize?
    let opensSettingsAtLaunch: Bool
    let contentState: ShellContentState
    let localizationMode: ShellLocalizationMode

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                MainSidebar(
                    navigationModel: navigationModel,
                    localizationMode: localizationMode
                )
                .navigationSplitViewColumnWidth(
                    min: CGFloat(MainWindowDefaults.sidebarWidthRange.lowerBound),
                    ideal: CGFloat(MainWindowDefaults.sidebarIdealWidth),
                    max: CGFloat(MainWindowDefaults.sidebarWidthRange.upperBound)
                )
            } detail: {
                MainSectionView(
                    navigationModel: navigationModel,
                    searchModel: searchModel,
                    searchFilterModel: searchFilterModel,
                    indexingBacklog: lifecycleModel.enrichmentBacklog.pendingCount,
                    contentState: contentState,
                    localizationMode: localizationMode,
                    availableWidth: geometry.size.width
                        - CGFloat(MainWindowDefaults.sidebarIdealWidth)
                )
            }
        }
        .frame(
            minWidth: CGFloat(MainWindowDefaults.minimumWidth),
            minHeight: CGFloat(MainWindowDefaults.minimumHeight)
        )
        .background(WindowContentSizeApplier(requestedSize: forcedWindowSize))
        .toolbar {
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .frame(
                    minWidth: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints),
                    minHeight: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints)
                )
                .help("Open Local Memory Settings")
                .accessibilityIdentifier("main.openSettings")
            }
        }
        .task {
            await navigationModel.start()
            if opensSettingsAtLaunch {
                openSettings()
            }
        }
        .onAppear { lifecycleModel.setMainWindowVisible(true) }
        .onDisappear { lifecycleModel.setMainWindowVisible(false) }
        .focusedSceneValue(\.shellCommandsActive, true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main.root")
    }
}

private struct MainSidebar: View {
    @ObservedObject var navigationModel: MainNavigationViewModel
    let localizationMode: ShellLocalizationMode

    var body: some View {
        List(selection: selection) {
            Section("Memory") {
                ForEach(MainNavigationSection.allCases, id: \.self) { section in
                    Label(
                        localizationMode.localized(section.title),
                        systemImage: section.systemImage
                    )
                    .tag(section)
                    .accessibilityIdentifier("sidebar.\(section.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Local Memory")
        .disabled(!navigationModel.isRestored)
        .accessibilityIdentifier("main.sidebar")
    }

    private var selection: Binding<MainNavigationSection?> {
        Binding(
            get: {
                navigationModel.isRestored ? navigationModel.snapshot.section : nil
            },
            set: { section in
                guard let section else { return }
                navigationModel.select(section: section)
            }
        )
    }
}

private struct MainSectionView: View {
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var searchFilterModel: SearchFilterSessionModel
    let indexingBacklog: Int
    let contentState: ShellContentState
    let localizationMode: ShellLocalizationMode
    let availableWidth: CGFloat
    @State private var showsQuickLook = false
    @State private var showsForgetConfirmation = false
    @State private var revisitNotice: String?

    private var selectedMoment: ShellMoment? {
        ShellMomentFixtures.moment(id: navigationModel.snapshot.selectedMomentID)
    }

    private var selectedSearchResult: SearchResult? {
        guard let selectedID = navigationModel.snapshot.selectedMomentID else { return nil }
        return searchModel.results.first { $0.frameID == selectedID }
    }

    private var showsInspector: Bool {
        MainWindowDefaults.showsInspector(
            width: availableWidth + CGFloat(MainWindowDefaults.sidebarIdealWidth),
            requested: navigationModel.snapshot.inspectorRequested
        ) && selectedMoment != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch navigationModel.snapshot.section {
                case .search:
                    MomentSectionCanvas(
                        title: "Search",
                        subtitle: "Find a moment you previously saw",
                        symbol: "magnifyingglass",
                        selectedMoment: selectedMoment,
                        selectedSearchResult: selectedSearchResult,
                        navigationModel: navigationModel,
                        searchModel: searchModel,
                        searchFilterModel: searchFilterModel,
                        indexingBacklog: indexingBacklog,
                        contentState: contentState,
                        localizationMode: localizationMode
                    )
                case .timeline:
                    SearchTimelineSectionView(
                        navigationModel: navigationModel,
                        searchModel: searchModel,
                        loader: searchModel.momentTimelineLoader,
                        revisitProvider: searchModel.momentRevisitProvider
                    )
                case .activity:
                    ActivityShellView(localizationMode: localizationMode)
                case .settings:
                    EmbeddedSettingsShellView(localizationMode: localizationMode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsInspector, let selectedMoment {
                Divider()
                MomentInspectorView(
                    moment: selectedMoment,
                    dismiss: { navigationModel.setInspectorRequested(false) }
                )
                .frame(
                    minWidth: CGFloat(MainWindowDefaults.inspectorWidthRange.lowerBound),
                    idealWidth: CGFloat(MainWindowDefaults.inspectorIdealWidth),
                    maxWidth: CGFloat(MainWindowDefaults.inspectorWidthRange.upperBound),
                    maxHeight: .infinity
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let revisitNotice {
                Text(revisitNotice)
                    .font(.callout)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("moment.revisitStatus")
                    .padding()
            }
        }
        .sheet(isPresented: $showsQuickLook, onDismiss: restoreSelectedMomentFocus) {
            VStack(spacing: 16) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 48))
                    .accessibilityHidden(true)
                Text(selectedMoment?.title ?? "Moment")
                    .font(.title2)
                Text("Synthetic local Quick Look preview")
                    .foregroundStyle(.secondary)
                Button("Close") { showsQuickLook = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(32)
            .frame(minWidth: 420, minHeight: 280)
            .accessibilityIdentifier("moment.quickLook")
        }
        .sheet(isPresented: $showsForgetConfirmation, onDismiss: restoreSelectedMomentFocus) {
            DestructiveConfirmationSheet(
                model: DestructiveConfirmationModel(
                    title: "Forget this moment?",
                    removalScope: "The selected moment will be hidden immediately.",
                    consequence:
                        "Its short video chunk will be rewritten when deletion is implemented.",
                    confirmLabel: "Forget Moment"
                ),
                onCancel: { showsForgetConfirmation = false },
                onConfirm: { showsForgetConfirmation = false }
            )
            .padding()
            .frame(minWidth: 480, minHeight: 280)
            .accessibilityIdentifier("moment.forgetConfirmation")
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellQuickLook)) { _ in
            showsQuickLook = selectedMoment != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellOpenDetail)) { _ in
            if selectedMoment != nil { navigationModel.setInspectorRequested(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellRevisit)) { _ in
            guard selectedMoment != nil else { return }
            revisitNotice = "Revisit is unavailable for this synthetic fixture."
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellPreviousTransition)) { _ in
            if let moment = ShellMomentFixtures.adjacent(
                to: navigationModel.snapshot.selectedMomentID,
                offset: -1
            ) {
                navigationModel.select(momentID: moment.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellNextTransition)) { _ in
            if let moment = ShellMomentFixtures.adjacent(
                to: navigationModel.snapshot.selectedMomentID,
                offset: 1
            ) {
                navigationModel.select(momentID: moment.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellForgetMoment)) { _ in
            showsForgetConfirmation = selectedMoment != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellEscape)) { _ in
            if showsQuickLook {
                showsQuickLook = false
            } else if showsForgetConfirmation {
                showsForgetConfirmation = false
            } else if revisitNotice != nil {
                revisitNotice = nil
            } else if selectedMoment != nil, navigationModel.snapshot.inspectorRequested {
                navigationModel.setInspectorRequested(false)
            } else {
                navigationModel.goBack()
            }
        }
        .toolbar {
            if selectedMoment != nil {
                ToolbarItem {
                    Button {
                        navigationModel.setInspectorRequested(
                            !navigationModel.snapshot.inspectorRequested
                        )
                    } label: {
                        Label("Toggle Inspector", systemImage: "sidebar.trailing")
                    }
                    .frame(
                        minWidth: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints),
                        minHeight: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints)
                    )
                    .help("Show or hide moment details")
                    .accessibilityIdentifier("main.toggleInspector")
                }
            }
        }
        .accessibilityIdentifier("main.section")
    }

    private func restoreSelectedMomentFocus() {
        NotificationCenter.default.post(name: .shellRestoreSelectedMomentFocus, object: nil)
    }
}

private struct MomentSectionCanvas: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selectedMoment: ShellMoment?
    let selectedSearchResult: SearchResult?
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var searchFilterModel: SearchFilterSessionModel
    let indexingBacklog: Int
    let contentState: ShellContentState
    let localizationMode: ShellLocalizationMode
    @FocusState private var searchIsFocused: Bool
    @FocusState private var focusedMomentID: UUID?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Label(localizationMode.localized(title), systemImage: symbol)
                    .font(.title2)
                    .accessibilityIdentifier("main.sectionTitle")
                Spacer()
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if title == "Search" {
                TextField("Search your local memory", text: queryBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .onSubmit { searchFilterModel.commitQuery() }
                    .accessibilityLabel("Search your local memory")
                    .accessibilityIdentifier("main.searchField")
                    .accessibilityHint("Searches only the local archive")

                SharedSearchFilterControls(filterModel: searchFilterModel)
            }

            if contentState == .ready {
                if title == "Search" {
                    if let selectedSearchResult {
                        SearchMomentDetailView(
                            result: selectedSearchResult,
                            navigationModel: navigationModel,
                            searchModel: searchModel,
                            repository: searchModel.momentDetailRepository,
                            exportProvider: searchModel.momentExportProvider,
                            timelineLoader: searchModel.momentTimelineLoader,
                            thumbnailRepository: searchModel.thumbnailRepository
                        )
                    } else {
                        SharedSearchResultsView(
                            searchModel: searchModel,
                            navigationModel: navigationModel,
                            filterModel: searchFilterModel,
                            indexingBacklog: indexingBacklog,
                            surface: .main
                        )
                    }
                } else {
                    List(Array(ShellMomentFixtures.moments.enumerated()), id: \.element.id) {
                        index, moment in
                        Button {
                            searchIsFocused = false
                            focusedMomentID = moment.id
                            navigationModel.select(momentID: moment.id)
                        } label: {
                            HStack {
                                Image(systemName: moment.systemImage)
                                    .frame(width: CGFloat(MainWindowDefaults.momentSymbolWidth))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(moment.title)
                                        .font(.headline)
                                    Text("\(moment.application) · \(moment.time)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedMoment?.id == moment.id {
                                    Image(systemName: "checkmark")
                                        .accessibilityLabel("Selected")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedMomentID, equals: moment.id)
                        .accessibilityLabel(
                            "\(moment.time), \(moment.application), \(moment.host), "
                                + "\(moment.evidenceType), \(index + 1) of "
                                + "\(ShellMomentFixtures.moments.count)"
                        )
                        .accessibilityHint("Open moment detail")
                        .accessibilityIdentifier("moment.\(moment.accessibilitySlug)")
                    }
                    GroupBox {
                        if let selectedMoment {
                            VStack {
                                Image(systemName: "rectangle.inset.filled.and.person.filled")
                                    .font(
                                        .system(
                                            size: CGFloat(MainWindowDefaults.previewSymbolSize)
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(selectedMoment.title)
                                    .font(.headline)
                                Text("Synthetic screenshot placeholder")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView(
                                "Choose a moment",
                                systemImage: "rectangle.stack.badge.clock",
                                description: Text(
                                    "Select a synthetic fixture to inspect its local provenance.")
                            )
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CGFloat(MainWindowDefaults.previewMinimumHeight),
                        maxHeight: .infinity
                    )
                }
            } else {
                standardState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .shellFocusSearch)) { _ in
            if title == "Search" {
                searchIsFocused = true
            } else {
                navigationModel.select(section: .search)
                Task { @MainActor in
                    await Task.yield()
                    NotificationCenter.default.post(name: .shellFocusSearch, object: nil)
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .shellRestoreSelectedMomentFocus)
        ) { _ in
            let selectedID = selectedMoment?.id
            focusedMomentID = nil
            Task { @MainActor in
                await Task.yield()
                focusedMomentID = selectedID
            }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { searchFilterModel.queryText },
            set: { searchFilterModel.updateQueryText($0) }
        )
    }

    @ViewBuilder
    private var standardState: some View {
        switch contentState {
        case .ready:
            EmptyView()
        case .empty:
            EmptyStateView(
                systemImage: "rectangle.stack.badge.clock",
                title: localizationMode.localized("No moments yet"),
                message: localizationMode.localized(
                    "Your screen memory will appear here after recording begins."
                ),
                actionTitle: localizationMode.localized("Check Capture Status")
            ) {
                navigationModel.select(section: .settings)
            }
        case .loading(let elapsedMilliseconds):
            ProgressStatusView(
                model: ProgressStatusModel(
                    label: localizationMode.localized("Loading local memory…"),
                    elapsedSeconds: Double(elapsedMilliseconds) / 1_000
                )
            )
            .accessibilityIdentifier("shell.loading")
        case .failure:
            InlineErrorView(
                message: localizationMode.localized("Local memory could not be loaded"),
                diagnosticCode: "LM-SHELL-500",
                retryTitle: localizationMode.localized("Try Again")
            )
        }
    }
}

private struct MomentInspectorView: View {
    let moment: ShellMoment
    let dismiss: () -> Void

    var body: some View {
        Form {
            HStack {
                Text("Moment Details")
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .frame(
                    minWidth: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints),
                    minHeight: CGFloat(ShellAccessibilityCatalog.minimumPointerTargetPoints)
                )
                .help("Hide inspector")
                .accessibilityLabel("Hide inspector")
                .accessibilityIdentifier("inspector.dismiss")
            }

            LabeledContent("Title") {
                Text(moment.title)
                    .accessibilityIdentifier("inspector.title")
            }
            LabeledContent("Time", value: moment.time)
            LabeledContent("Application", value: moment.application)
            LabeledContent("Context", value: moment.context)
            LabeledContent("Source", value: "Synthetic fixture")

            Section("Actions") {
                Button("Open or Revisit") {}
                    .disabled(true)
                Button("Export Moment…") {}
                    .disabled(true)
                Button("Forget Moment…", role: .destructive) {}
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main.inspector")
    }
}

private struct ActivityShellView: View {
    let localizationMode: ShellLocalizationMode

    var body: some View {
        VStack(alignment: .leading) {
            Label(localizationMode.localized("Activity"), systemImage: "chart.xyaxis.line")
                .font(.title2)
                .accessibilityIdentifier("main.sectionTitle")
            Text("Activity estimates")
                .font(.headline)
            Text(
                "Recorded, idle, paused, and missing time will be shown here without scores or rankings."
            )
            .foregroundStyle(.secondary)
            GroupBox("Activity accessibility table") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Date and hour").font(.headline)
                        Text("Recorded").font(.headline)
                        Text("Gap").font(.headline)
                    }
                    GridRow {
                        Text("Today, 2 PM")
                        Text("42 minutes")
                        Text("18 minutes")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today, 2 PM, 42 recorded minutes, 18 gap minutes")
            }
            .accessibilityIdentifier("activity.accessibilityTable")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private struct EmbeddedSettingsShellView: View {
    let localizationMode: ShellLocalizationMode

    var body: some View {
        Form {
            Text(localizationMode.localized("Settings"))
                .font(.title2)
                .accessibilityIdentifier("main.sectionTitle")
            Section("Capture") {
                LabeledContent("Privacy mode", value: "Foreground window only")
                LabeledContent("Recording controls", value: "Managed locally")
            }
            Section("Open the full Settings window") {
                Text(
                    "Use the toolbar Settings button for Capture, Privacy, Storage, Search, Agents, and Diagnostics."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private enum LocalMemorySettingsSection: Hashable {
    case capture
    case privacy
    case storage
    case search
    case agents
    case about
}

struct LocalMemorySettingsView: View {
    @ObservedObject var lifecycleModel: AppLifecycleViewModel
    @ObservedObject var launchAtLoginModel: LaunchAtLoginViewModel
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator
    @ObservedObject var privacySettingsModel: PrivacySettingsViewModel
    @ObservedObject var archiveSecurityModel: ArchiveSecurityViewModel
    @State private var selection: LocalMemorySettingsSection

    init(
        lifecycleModel: AppLifecycleViewModel,
        launchAtLoginModel: LaunchAtLoginViewModel,
        searchPanelCoordinator: GlobalSearchPanelCoordinator,
        privacySettingsModel: PrivacySettingsViewModel,
        archiveSecurityModel: ArchiveSecurityViewModel,
        opensPrivacyAtLaunch: Bool
    ) {
        self.lifecycleModel = lifecycleModel
        self.launchAtLoginModel = launchAtLoginModel
        self.searchPanelCoordinator = searchPanelCoordinator
        self.privacySettingsModel = privacySettingsModel
        self.archiveSecurityModel = archiveSecurityModel
        _selection = State(initialValue: opensPrivacyAtLaunch ? .privacy : .capture)
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureSettingsPane(
                lifecycleModel: lifecycleModel,
                launchAtLoginModel: launchAtLoginModel,
                searchPanelCoordinator: searchPanelCoordinator
            )
            .tabItem { Label("Capture", systemImage: "record.circle") }
            .tag(LocalMemorySettingsSection.capture)

            PrivacySettingsPane(model: privacySettingsModel)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(LocalMemorySettingsSection.privacy)

            ArchiveSecuritySettingsPane(model: archiveSecurityModel)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(LocalMemorySettingsSection.storage)

            SettingsPane(
                title: "Search & Models",
                systemImage: "magnifyingglass",
                rows: [
                    ("Visual model", "Bundled local model"),
                    ("Runtime downloads", "Never"),
                    ("Index", "Synthetic preview"),
                ]
            )
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(LocalMemorySettingsSection.search)

            SettingsPane(
                title: "Agent Access",
                systemImage: "terminal",
                rows: [
                    ("Approved policies", "None"),
                    ("Unbounded access", "Not available"),
                    ("Audit", "Local and content-free"),
                ]
            )
            .tabItem { Label("Agents", systemImage: "terminal") }
            .tag(LocalMemorySettingsSection.agents)

            SettingsPane(
                title: "About & Diagnostics",
                systemImage: "info.circle",
                rows: [
                    ("Product", "Local Memory"),
                    ("Network", "Disabled during normal use"),
                    ("Diagnostics", "Local only"),
                ]
            )
            .tabItem { Label("About", systemImage: "info.circle") }
            .tag(LocalMemorySettingsSection.about)
        }
        .frame(
            width: CGFloat(MainWindowDefaults.settingsWidth),
            height: CGFloat(MainWindowDefaults.settingsHeight)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
    }
}

private struct ArchiveSecuritySettingsPane: View {
    @ObservedObject var model: ArchiveSecurityViewModel

    var body: some View {
        Form {
            Label("Storage", systemImage: "externaldrive")
                .font(.title2)
                .accessibilityIdentifier("settings.title")
            Section("Archive") {
                LabeledContent("Default retention", value: "30 days")
                LabeledContent("Default cap", value: "20 GB")
                LabeledContent("Location", value: "Stored locally")
                LabeledContent("Database text", value: encryptionStatus)
                    .accessibilityIdentifier("storage.encryptionStatus")
                Text(
                    "Searchable text, settings, and audit rows are SQLCipher-encrypted. Visual media relies on owner-only permissions and FileVault when enabled."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.state == .unrecoverableKey {
                Section("Archive key unavailable") {
                    Label(
                        "The existing encrypted database cannot be opened because its Keychain key is missing or no longer unlocks it. Local Memory will not replace the key or overwrite the archive automatically.",
                        systemImage: "key.slash"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("storage.unrecoverableKey")
                    Text(
                        "Reset permanently deletes the database, media, thumbnails, vectors, exports, and local logs. This cannot be undone."
                    )
                    Text("Type \(ArchiveResetCoordinator.requiredConfirmation) to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        ArchiveResetCoordinator.requiredConfirmation,
                        text: $model.typedResetConfirmation
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("storage.resetConfirmation")
                    Button("Delete Archive and Create a New Key", role: .destructive) {
                        model.resetUnrecoverableArchive()
                    }
                    .disabled(!model.canReset)
                    .accessibilityIdentifier("storage.resetArchive")
                }
            } else if case .unavailable(let errorCode) = model.state {
                Section("Archive unavailable") {
                    Label(
                        "The local archive could not be opened",
                        systemImage: "exclamationmark.triangle"
                    )
                    Text("No history is being stored. Error code: \(errorCode).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var encryptionStatus: String {
        switch model.state {
        case .ready: "Encrypted and verified"
        case .unrecoverableKey: "Key missing — recording stopped"
        case .unavailable: "Unavailable — recording stopped"
        }
    }
}

private struct CaptureSettingsPane: View {
    @ObservedObject var lifecycleModel: AppLifecycleViewModel
    @ObservedObject var launchAtLoginModel: LaunchAtLoginViewModel
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator

    var body: some View {
        Form {
            Label("Capture", systemImage: "record.circle")
                .font(.title2)
                .accessibilityIdentifier("settings.title")
            Section {
                LabeledContent("Status", value: lifecycleModel.menuProjection.statusLabel)
                    .accessibilityIdentifier("settings.captureStatus")
                if let detail = lifecycleModel.menuProjection.detailLabel {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.captureDetail")
                }
                LabeledContent("Privacy mode", value: "Foreground window only")
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLoginModel.isEnabled },
                        set: { launchAtLoginModel.setEnabled($0) }
                    )
                )
                .accessibilityIdentifier("settings.launchAtLogin")
                LabeledContent("Login item status", value: launchAtLoginModel.snapshot.statusLabel)
                    .accessibilityIdentifier("settings.launchAtLoginStatus")
                if launchAtLoginModel.snapshot.humanGate == .approveInLoginItems {
                    Text("Approve Local Memory in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.launchAtLoginApproval")
                }
                if let errorCode = launchAtLoginModel.errorCode {
                    LabeledContent("Login item diagnostic", value: errorCode)
                        .accessibilityIdentifier("settings.launchAtLoginError")
                }
            }
            Section("Global search shortcut") {
                Picker(
                    "Shortcut",
                    selection: Binding(
                        get: { searchPanelCoordinator.shortcut },
                        set: { searchPanelCoordinator.setShortcut($0) }
                    )
                ) {
                    Text(GlobalSearchShortcut.default.displayName)
                        .tag(GlobalSearchShortcut.default)
                    Text("Command–Shift–K")
                        .tag(GlobalSearchShortcut(key: .k, modifiers: [.command, .shift]))
                }
                .accessibilityIdentifier("settings.shortcut")
                LabeledContent(
                    "Registration",
                    value: searchPanelCoordinator.registrationState.statusLabel
                )
                .accessibilityIdentifier("settings.shortcutStatus")
                if let diagnosticCode = searchPanelCoordinator.registrationState.diagnosticCode {
                    LabeledContent("Diagnostic", value: diagnosticCode)
                        .accessibilityIdentifier("settings.shortcutDiagnostic")
                }
                if let actionTitle = searchPanelCoordinator.registrationState.recoveryActionTitle {
                    Button(actionTitle) {
                        searchPanelCoordinator.chooseRecoveryShortcut()
                    }
                    .accessibilityIdentifier("settings.shortcutRecovery")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await searchPanelCoordinator.start()
            await launchAtLoginModel.start()
        }
    }
}

private struct SettingsPane: View {
    let title: String
    let systemImage: String
    let rows: [(String, String)]

    var body: some View {
        Form {
            Label(title, systemImage: systemImage)
                .font(.title2)
                .accessibilityIdentifier("settings.title")
            Section {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WindowContentSizeApplier: NSViewRepresentable {
    let requestedSize: MainWindowLaunchSize?

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.configure = { window in
            guard let requestedSize else { return }
            window.setContentSize(NSSize(width: requestedSize.width, height: requestedSize.height))
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        nsView.configure = { window in
            guard let requestedSize else { return }
            window.setContentSize(NSSize(width: requestedSize.width, height: requestedSize.height))
            window.center()
        }
        nsView.scheduleApply()
    }
}

private final class WindowAttachmentView: NSView {
    var configure: ((NSWindow) -> Void)?
    private var applied = false
    private var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleApply()
    }

    func scheduleApply() {
        guard !applied, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            scheduled = false
            guard !applied, let window else {
                scheduleApply()
                return
            }
            applied = true
            configure?(window)
        }
    }
}
