import AppKit
import Foundation
import MemoryDesignSystem
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
        snapshot = MainNavigationSnapshot(
            section: section,
            selectedMomentID: snapshot.selectedMomentID,
            inspectorRequested: snapshot.inspectorRequested
        )
        enqueuePersistence()
    }

    func select(momentID: UUID) {
        guard isRestored, snapshot.selectedMomentID != momentID else { return }
        snapshot = MainNavigationSnapshot(
            section: snapshot.section,
            selectedMomentID: momentID,
            inspectorRequested: snapshot.inspectorRequested
        )
        enqueuePersistence()
    }

    func setInspectorRequested(_ requested: Bool) {
        guard isRestored, snapshot.inspectorRequested != requested else { return }
        snapshot = MainNavigationSnapshot(
            section: snapshot.section,
            selectedMomentID: snapshot.selectedMomentID,
            inspectorRequested: requested
        )
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
    let systemImage: String
}

private enum ShellMomentFixtures {
    static let moments = [
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
            accessibilitySlug: "morning-planning",
            title: "Morning planning",
            application: "Calendar",
            time: "9:12 AM",
            context: "Local fixture · Planning window",
            systemImage: "calendar"
        ),
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!,
            accessibilitySlug: "afternoon-research",
            title: "Afternoon research",
            application: "Safari",
            time: "2:14 PM",
            context: "example.test · Research notes",
            systemImage: "safari"
        ),
        ShellMoment(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000103")!,
            accessibilitySlug: "evening-notes",
            title: "Evening notes",
            application: "Notes",
            time: "5:42 PM",
            context: "Local fixture · Daily notes",
            systemImage: "note.text"
        ),
    ]

    static func moment(id: UUID?) -> ShellMoment? {
        moments.first { $0.id == id }
    }
}

struct MainShellView: View {
    @ObservedObject var lifecycleModel: AppLifecycleViewModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    let forcedWindowSize: MainWindowLaunchSize?
    let opensSettingsAtLaunch: Bool

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                MainSidebar(navigationModel: navigationModel)
                    .navigationSplitViewColumnWidth(
                        min: CGFloat(MainWindowDefaults.sidebarWidthRange.lowerBound),
                        ideal: CGFloat(MainWindowDefaults.sidebarIdealWidth),
                        max: CGFloat(MainWindowDefaults.sidebarWidthRange.upperBound)
                    )
            } detail: {
                MainSectionView(
                    navigationModel: navigationModel,
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main.root")
    }
}

private struct MainSidebar: View {
    @ObservedObject var navigationModel: MainNavigationViewModel

    var body: some View {
        List(selection: selection) {
            Section("Memory") {
                ForEach(MainNavigationSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
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
    let availableWidth: CGFloat

    private var selectedMoment: ShellMoment? {
        ShellMomentFixtures.moment(id: navigationModel.snapshot.selectedMomentID)
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
                        navigationModel: navigationModel
                    )
                case .timeline:
                    MomentSectionCanvas(
                        title: "Timeline",
                        subtitle: "Today · Synthetic local fixture",
                        symbol: "clock.arrow.circlepath",
                        selectedMoment: selectedMoment,
                        navigationModel: navigationModel
                    )
                case .activity:
                    ActivityShellView()
                case .settings:
                    EmbeddedSettingsShellView()
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
                    .help("Show or hide moment details")
                    .accessibilityIdentifier("main.toggleInspector")
                }
            }
        }
        .accessibilityIdentifier("main.section")
    }
}

private struct MomentSectionCanvas: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selectedMoment: ShellMoment?
    @ObservedObject var navigationModel: MainNavigationViewModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.title2)
                    .accessibilityIdentifier("main.sectionTitle")
                Spacer()
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if title == "Search" {
                TextField("Search your local memory", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .accessibilityHint("Search is connected in a later implementation phase")
            }

            List(ShellMomentFixtures.moments) { moment in
                Button {
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
                .accessibilityIdentifier("moment.\(moment.accessibilitySlug)")
            }

            GroupBox {
                if let selectedMoment {
                    VStack {
                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: CGFloat(MainWindowDefaults.previewSymbolSize)))
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
                        description: Text("Select a synthetic fixture to inspect its local provenance.")
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: CGFloat(MainWindowDefaults.previewMinimumHeight),
                maxHeight: .infinity
            )
        }
        .padding()
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
                .help("Hide inspector")
                .accessibilityLabel("Hide inspector")
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
    var body: some View {
        VStack(alignment: .leading) {
            Label("Activity", systemImage: "chart.xyaxis.line")
                .font(.title2)
                .accessibilityIdentifier("main.sectionTitle")
            Text("Activity estimates")
                .font(.headline)
            Text("Recorded, idle, paused, and missing time will be shown here without scores or rankings.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private struct EmbeddedSettingsShellView: View {
    var body: some View {
        Form {
            Text("Settings")
                .font(.title2)
                .accessibilityIdentifier("main.sectionTitle")
            Section("Capture") {
                LabeledContent("Privacy mode", value: "Foreground window only")
                LabeledContent("Recording controls", value: "Managed locally")
            }
            Section("Open the full Settings window") {
                Text("Use the toolbar Settings button for Capture, Privacy, Storage, Search, Agents, and Diagnostics.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LocalMemorySettingsView: View {
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator

    var body: some View {
        TabView {
            CaptureSettingsPane(searchPanelCoordinator: searchPanelCoordinator)
            .tabItem { Label("Capture", systemImage: "record.circle") }

            SettingsPane(
                title: "Privacy",
                systemImage: "hand.raised",
                rows: [
                    ("Applications", "No custom exclusions yet"),
                    ("Sites", "Protected URL rules arrive later"),
                    ("Private windows", "Fail closed"),
                ]
            )
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            SettingsPane(
                title: "Storage",
                systemImage: "externaldrive",
                rows: [
                    ("Default retention", "30 days"),
                    ("Default cap", "20 GB"),
                    ("Archive", "Stored locally"),
                ]
            )
            .tabItem { Label("Storage", systemImage: "externaldrive") }

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
        }
        .frame(
            width: CGFloat(MainWindowDefaults.settingsWidth),
            height: CGFloat(MainWindowDefaults.settingsHeight)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
    }
}

private struct CaptureSettingsPane: View {
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator

    var body: some View {
        Form {
            Label("Capture", systemImage: "record.circle")
                .font(.title2)
                .accessibilityIdentifier("settings.title")
            Section {
                LabeledContent("Status", value: "Fake runtime until capture integration")
                LabeledContent("Privacy mode", value: "Foreground window only")
                LabeledContent("Launch at login", value: "Connected in a later phase")
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
        .task { await searchPanelCoordinator.start() }
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
