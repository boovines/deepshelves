import MemoryDesignSystem
import SwiftUI
import AppKit

extension Notification.Name {
    static let shellFocusSearch = Notification.Name("LocalMemory.shell.focusSearch")
    static let shellQuickLook = Notification.Name("LocalMemory.shell.quickLook")
    static let shellOpenDetail = Notification.Name("LocalMemory.shell.openDetail")
    static let shellRevisit = Notification.Name("LocalMemory.shell.revisit")
    static let shellPreviousTransition = Notification.Name("LocalMemory.shell.previousTransition")
    static let shellNextTransition = Notification.Name("LocalMemory.shell.nextTransition")
    static let shellForgetMoment = Notification.Name("LocalMemory.shell.forgetMoment")
    static let shellEscape = Notification.Name("LocalMemory.shell.escape")
    static let shellRestoreSelectedMomentFocus = Notification.Name(
        "LocalMemory.shell.restoreSelectedMomentFocus"
    )
}

private struct ShellCommandsActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var shellCommandsActive: Bool? {
        get { self[ShellCommandsActiveKey.self] }
        set { self[ShellCommandsActiveKey.self] = newValue }
    }
}

struct LocalMemoryCommands: Commands {
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchPanelCoordinator: GlobalSearchPanelCoordinator
    @FocusedValue(\.shellCommandsActive) private var shellCommandsActive

    var body: some Commands {
        CommandMenu("Find") {
            Button("Focus Search") { post(.shellFocusSearch) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(shellCommandsActive != true)
        }

        CommandMenu("Navigate") {
            Button("Search") { navigationModel.select(section: .search) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(shellCommandsActive != true)
            Button("Timeline") { navigationModel.select(section: .timeline) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(shellCommandsActive != true)
            Button("Activity") { navigationModel.select(section: .activity) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(shellCommandsActive != true)
            Divider()
            Button("Back") { navigationModel.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(shellCommandsActive != true || !navigationModel.canGoBack)
            Button("Forward") { navigationModel.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(shellCommandsActive != true || !navigationModel.canGoForward)
            Divider()
            Button("Global Search Panel — Option-Space") { searchPanelCoordinator.toggle() }
        }

        CommandMenu("Moment") {
            Button("Quick Look") { post(.shellQuickLook) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(shellCommandsActive != true)
            Button("Open Detail") { post(.shellOpenDetail) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(shellCommandsActive != true)
            Button("Revisit Source") { post(.shellRevisit) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(shellCommandsActive != true)
            Divider()
            Button("Previous Application Transition") { post(.shellPreviousTransition) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(shellCommandsActive != true)
            Button("Next Application Transition") { post(.shellNextTransition) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(shellCommandsActive != true)
            Divider()
            Button("Forget Selected Moment…", role: .destructive) { post(.shellForgetMoment) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(shellCommandsActive != true)
            Button("Close Transient UI") { post(.shellEscape) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(shellCommandsActive != true)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

@MainActor
final class ShellKeyboardCommandMonitor {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handle(event) == true ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let keyWindow = NSApp.keyWindow
        let owningWindowTitle = keyWindow?.sheetParent?.title ?? keyWindow?.title
        guard owningWindowTitle == "Local Memory" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let command = modifiers.contains(.command)
        let option = modifiers.contains(.option)
        let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView
        let editedField = fieldEditor?.delegate as? NSTextField
        let isEditingText = editedField?.currentEditor() === fieldEditor
        let notification: Notification.Name?
        if event.keyCode == 36 || event.keyCode == 76 {
            if command {
                notification = .shellRevisit
            } else if modifiers.isEmpty {
                notification = .shellOpenDetail
            } else {
                notification = nil
            }
            if let notification {
                NotificationCenter.default.post(name: notification, object: nil)
                return true
            }
            return false
        }
        switch event.keyCode {
        case 49 where modifiers.isEmpty && !isEditingText:
            notification = .shellQuickLook
        case 123 where option:
            notification = .shellPreviousTransition
        case 124 where option:
            notification = .shellNextTransition
        case 51 where command:
            notification = .shellForgetMoment
        case 53:
            notification = .shellEscape
        default:
            notification = nil
        }
        guard let notification else { return false }
        NotificationCenter.default.post(name: notification, object: nil)
        return true
    }
}
