import Foundation
import MemoryDesignSystem
import SwiftUI

@MainActor
final class AppearanceSettingsViewModel: ObservableObject {
    @Published private(set) var selection: MemoryAppearanceMode = .light
    @Published private(set) var isLoaded = false
    @Published private(set) var errorCode: String?

    private let store: FileMemoryAppearanceStateStore
    private var loadTask: Task<MemoryAppearanceState, Error>?
    private var persistenceTask: Task<Void, Never>?

    init(stateURL: URL) {
        store = FileMemoryAppearanceStateStore(fileURL: stateURL)
        Task { [weak self] in await self?.load() }
    }

    var preferredColorScheme: ColorScheme? {
        switch selection {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func load() async {
        guard !isLoaded else { return }
        let task: Task<MemoryAppearanceState, Error>
        if let loadTask {
            task = loadTask
        } else {
            let store = store
            let created = Task { try await store.load() }
            loadTask = created
            task = created
        }
        do {
            selection = try await task.value.mode
            errorCode = nil
        } catch {
            selection = .light
            errorCode = "LM-APPEARANCE-LOAD"
        }
        isLoaded = true
    }

    func select(_ mode: MemoryAppearanceMode) {
        guard selection != mode else { return }
        let previous = selection
        let previousTask = persistenceTask
        let store = store
        selection = mode
        persistenceTask = Task { [weak self] in
            _ = await previousTask?.result
            do {
                try await store.save(MemoryAppearanceState(mode: mode))
                guard self?.selection == mode else { return }
                self?.errorCode = nil
            } catch {
                guard self?.selection == mode else { return }
                self?.selection = previous
                self?.errorCode = "LM-APPEARANCE-SAVE"
            }
        }
    }
}

struct AppearanceSettingsPane: View {
    @ObservedObject var model: AppearanceSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.sectionLarge) {
            SettingsGroupedCard {
                VStack(alignment: .leading, spacing: MemorySpacing.large) {
                    SettingsRowHeader(
                        systemImage: "circle.lefthalf.filled",
                        title: "Appearance",
                        detail: "Choose how Local Memory surfaces respond to macOS appearance."
                    )
                    HStack(spacing: MemorySpacing.large) {
                        ForEach(MemoryAppearanceMode.allCases, id: \.self) { mode in
                            Button {
                                model.select(mode)
                            } label: {
                                VStack(spacing: MemorySpacing.small) {
                                    AppearancePreview(
                                        mode: mode,
                                        isSelected: model.selection == mode
                                    )
                                    HStack(spacing: MemorySpacing.xSmall) {
                                        Text(mode.title)
                                        if model.selection == mode {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                    .font(.callout.weight(.medium))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(mode.title) appearance, "
                                    + (model.selection == mode ? "selected" : "not selected")
                            )
                            .accessibilityIdentifier("appearance.\(mode.rawValue)")
                        }
                    }
                }
            }

            SettingsGroupedCard {
                SettingsRowHeader(
                    systemImage: "paintpalette",
                    title: "Accent color",
                    detail: "Azure is used consistently for focus, selection, and primary actions."
                )
            }

            if let errorCode = model.errorCode {
                InlineErrorView(
                    message: "Appearance could not be saved",
                    diagnosticCode: errorCode,
                    retryTitle: "Try Again"
                )
            }
        }
        .task { await model.load() }
    }
}

struct SettingsGroupedCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(MemorySpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MemoryColorToken.surfaceControl.color,
                in: RoundedRectangle(cornerRadius: MemoryRadius.groupedCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MemoryRadius.groupedCard, style: .continuous)
                    .stroke(MemoryColorToken.borderDefault.color.opacity(0.7), lineWidth: 0.5)
            }
    }
}

struct SettingsRowHeader: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: MemorySpacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
                .frame(width: 36, height: 36)
                .background(
                    MemoryColorToken.surfaceSidebar.color,
                    in: RoundedRectangle(cornerRadius: MemoryRadius.card)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MemorySpacing.xSmall) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppearancePreview: View {
    let mode: MemoryAppearanceMode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            if mode == .system {
                previewHalf(background: Color(nsColor: .windowBackgroundColor), dark: false)
                previewHalf(background: Color(nsColor: .darkGray), dark: true)
            } else {
                previewHalf(
                    background: mode == .light
                        ? Color.white : Color(red: 0.08, green: 0.09, blue: 0.11),
                    dark: mode == .dark
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .clipShape(RoundedRectangle(cornerRadius: MemoryRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MemoryRadius.card, style: .continuous)
                .stroke(
                    isSelected
                        ? MemoryColorToken.accent.color : MemoryColorToken.borderDefault.color,
                    lineWidth: 2
                )
        }
    }

    private func previewHalf(background: Color, dark: Bool) -> some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(.blue).frame(width: 36, height: 6)
                Capsule().fill(dark ? .white.opacity(0.58) : .black.opacity(0.30)).frame(height: 6)
                Capsule().fill(dark ? .white.opacity(0.34) : .black.opacity(0.16)).frame(
                    width: 52, height: 6)
            }
            .padding(16)
        }
    }
}
