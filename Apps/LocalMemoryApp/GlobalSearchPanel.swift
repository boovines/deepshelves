import AppKit
import Carbon.HIToolbox
import MemoryDesignSystem
import MemorySearch
import SwiftUI

private let globalSearchHotKeyID = EventHotKeyID(
    signature: OSType(0x4C4D_5352),
    id: 1
)

private func globalSearchHotKeyHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonGlobalSearchShortcutRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        registrar.handleHotKeyPressed()
    }
    return noErr
}

@MainActor
private final class CarbonGlobalSearchShortcutRegistrar {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register(_ shortcut: GlobalSearchShortcut) -> OSStatus {
        unregister()
        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                globalSearchHotKeyHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
            guard installStatus == noErr else { return installStatus }
        }

        return RegisterEventHotKey(
            keyCode(for: shortcut.key),
            carbonModifiers(for: shortcut.modifiers),
            globalSearchHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    func handleHotKeyPressed() {
        action()
    }

    private func keyCode(for key: GlobalShortcutKey) -> UInt32 {
        switch key {
        case .space: UInt32(kVK_Space)
        case .k: UInt32(kVK_ANSI_K)
        }
    }

    private func carbonModifiers(for modifiers: GlobalShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

@MainActor
final class GlobalSearchPanelCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var snapshot = GlobalSearchPanelSnapshot.default
    @Published private(set) var lastPresentationMilliseconds = 0
    @Published private(set) var coldPresentationMilliseconds: Int?
    @Published private(set) var warmPresentationMilliseconds: Int?

    private let navigationModel: MainNavigationViewModel
    private let searchModel: SearchSessionModel
    private let store: FileGlobalSearchPanelStateStore
    private let simulatesShortcutCollision: Bool
    private var registrar: CarbonGlobalSearchShortcutRegistrar!
    private var panel: GlobalSearchNSPanel?
    private var startupTask: Task<Void, Never>?

    init(
        navigationModel: MainNavigationViewModel,
        searchModel: SearchSessionModel,
        stateURL: URL,
        simulatesShortcutCollision: Bool
    ) {
        self.navigationModel = navigationModel
        self.searchModel = searchModel
        store = FileGlobalSearchPanelStateStore(fileURL: stateURL)
        self.simulatesShortcutCollision = simulatesShortcutCollision
        super.init()
        registrar = CarbonGlobalSearchShortcutRegistrar { [weak self] in
            self?.toggle()
        }
        startupTask = Task { [weak self] in
            await self?.restoreAndRegister()
        }
    }

    var shortcut: GlobalSearchShortcut { snapshot.shortcut }
    var registrationState: GlobalShortcutRegistrationState { snapshot.registrationState }

    func start() async {
        await startupTask?.value
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            present()
        }
    }

    func present() {
        let start = ContinuousClock.now
        let isWarm = panel != nil
        let panel = panel ?? makePanel()
        self.panel = panel
        applyPlacement(to: panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        let duration = start.duration(to: .now).components
        lastPresentationMilliseconds =
            Int(duration.seconds * 1_000)
            + Int(duration.attoseconds / 1_000_000_000_000_000)
        if isWarm {
            warmPresentationMilliseconds = lastPresentationMilliseconds
        } else {
            coldPresentationMilliseconds = lastPresentationMilliseconds
        }
    }

    func close() {
        rememberDisplay(for: panel)
        panel?.orderOut(nil)
    }

    func chooseRecoveryShortcut() {
        setShortcut(GlobalSearchShortcut(key: .k, modifiers: [.command, .shift]))
    }

    func setShortcut(_ shortcut: GlobalSearchShortcut) {
        configure(shortcut, ignoresSimulation: true)
    }

    func windowDidMove(_ notification: Notification) {
        rememberDisplay(for: notification.object as? NSWindow)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberDisplay(for: notification.object as? NSWindow)
    }

    func windowWillClose(_ notification: Notification) {
        rememberDisplay(for: notification.object as? NSWindow)
    }

    private func restoreAndRegister() async {
        let restored = (try? await store.load()) ?? .default
        snapshot = restored
        configure(restored.shortcut, ignoresSimulation: false)
    }

    private func configure(_ shortcut: GlobalSearchShortcut, ignoresSimulation: Bool) {
        let registrationState: GlobalShortcutRegistrationState
        if simulatesShortcutCollision, !ignoresSimulation {
            registrar.unregister()
            registrationState = .collision(
                shortcut: shortcut,
                diagnosticCode: "LM-SHORTCUT-409"
            )
        } else {
            let status = registrar.register(shortcut)
            if status == noErr {
                registrationState = .registered(shortcut: shortcut)
            } else {
                registrationState = .collision(
                    shortcut: shortcut,
                    diagnosticCode: "LM-SHORTCUT-\(status)"
                )
            }
        }
        snapshot = GlobalSearchPanelSnapshot(
            shortcut: shortcut,
            rememberedDisplayIdentifier: snapshot.rememberedDisplayIdentifier,
            registrationState: registrationState
        )
        persist()
    }

    private func makePanel() -> GlobalSearchNSPanel {
        let panel = GlobalSearchNSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: GlobalSearchPanelDefaults.width,
                height: GlobalSearchPanelDefaults.height
            ),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Search Local Memory"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.minSize = NSSize(
            width: GlobalSearchPanelDefaults.minimumWidth,
            height: GlobalSearchPanelDefaults.minimumHeight
        )
        panel.escapeAction = { [weak self] in self?.close() }
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: GlobalSearchPanelView(
                navigationModel: navigationModel,
                searchModel: searchModel,
                coordinator: self
            )
        )
        panel.setAccessibilityIdentifier("search.panel")
        return panel
    }

    private func applyPlacement(to panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { screen in
            SearchPanelDisplayDescriptor(
                identifier: Self.identifier(for: screen),
                visibleFrame: SearchPanelRectangle(
                    x: screen.visibleFrame.origin.x,
                    y: screen.visibleFrame.origin.y,
                    width: screen.visibleFrame.width,
                    height: screen.visibleFrame.height
                ),
                containsPointer: screen.visibleFrame.contains(pointer)
            )
        }
        guard
            let placement = try? GlobalSearchPanelPlacement.resolve(
                displays: screens,
                rememberedDisplayIdentifier: snapshot.rememberedDisplayIdentifier
            )
        else {
            panel.center()
            return
        }
        panel.setFrame(
            NSRect(
                x: placement.frame.x,
                y: placement.frame.y,
                width: placement.frame.width,
                height: placement.frame.height
            ),
            display: false
        )
    }

    private func rememberDisplay(for window: NSWindow?) {
        guard let screen = window?.screen else { return }
        let identifier = Self.identifier(for: screen)
        guard snapshot.rememberedDisplayIdentifier != identifier else { return }
        snapshot = GlobalSearchPanelSnapshot(
            shortcut: snapshot.shortcut,
            rememberedDisplayIdentifier: identifier,
            registrationState: snapshot.registrationState
        )
        persist()
    }

    private func persist() {
        let snapshot = snapshot
        Task { try? await store.save(snapshot) }
    }

    private static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue
            ?? String(describing: screen.frame)
    }
}

private final class GlobalSearchNSPanel: NSPanel {
    var escapeAction: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeAction?()
    }
}

private struct GlobalSearchPanelView: View {
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var coordinator: GlobalSearchPanelCoordinator
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search your local memory", text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($searchIsFocused)
                    .accessibilityIdentifier("search.query")
                Text(coordinator.shortcut.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Divider()

            SharedSearchResultsView(
                searchModel: searchModel,
                navigationModel: navigationModel,
                surface: .panel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Shared with \(navigationModel.snapshot.section.title)")
                    .accessibilityIdentifier("search.sharedSection")
                Spacer()
                Text(presentationTimingLabel)
                    .accessibilityIdentifier("search.presentationTiming")
                Text("Esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .background(.regularMaterial)
        .frame(
            minWidth: CGFloat(GlobalSearchPanelDefaults.minimumWidth),
            minHeight: CGFloat(GlobalSearchPanelDefaults.minimumHeight)
        )
        .task {
            await navigationModel.start()
            await coordinator.start()
            searchIsFocused = true
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                searchIsFocused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.content")
    }

    private var presentationTimingLabel: String {
        let cold = coordinator.coldPresentationMilliseconds.map(String.init) ?? "pending"
        let warm = coordinator.warmPresentationMilliseconds.map(String.init) ?? "pending"
        return "Cold \(cold) ms · Warm \(warm) ms"
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { searchModel.query },
            set: { searchModel.updateQuery($0) }
        )
    }
}
