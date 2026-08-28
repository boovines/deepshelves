import SwiftUI

public struct MemoryComponentBaselineBoard: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            VStack(alignment: .leading, spacing: MemorySpacing.medium) {
                header

                HStack(alignment: .top, spacing: compact ? MemorySpacing.small : MemorySpacing.large) {
                    controlsColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    resultColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    trustColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                DestructiveConfirmationSheet(
                    model: DestructiveConfirmationModel(
                        title: "Forget this moment?",
                        removalScope: "The selected screenshot, searchable text, and local vector will be removed.",
                        consequence: "The underlying short video chunk will be rewritten.",
                        confirmLabel: "Forget Moment"
                    ),
                    compact: true
                )
                .frame(maxWidth: geometry.size.width * 0.72)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    MemoryColorToken.surfaceControl.color,
                    in: RoundedRectangle(cornerRadius: MemoryRadius.card)
                )
            }
            .padding(compact ? MemorySpacing.small : MemorySpacing.xLarge)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(MemoryColorToken.surfaceWindow.color)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: MemorySpacing.xSmall) {
                Text("Local Memory shared controls")
                    .font(MemoryTypeToken.title2.font)
                Text("Synthetic fixtures • foreground-window-only product language")
                    .font(MemoryTypeToken.caption.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
            }
            Spacer()
            CaptureStatusBadge(state: .recording)
        }
    }

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.medium) {
            MemorySearchField(
                text: .constant("yellow lamp yesterday"),
                model: MemorySearchFieldModel(
                    text: "yellow lamp yesterday",
                    initiallyFocused: false,
                    state: .focused
                )
            )

            FilterToken(
                model: FilterTokenModel(
                    id: "selected-time",
                    label: "Yesterday",
                    systemImage: "calendar",
                    isSelected: true
                ),
                state: .selected
            )

            FilterTokenBar(
                tokens: [
                    FilterTokenModel(id: "app", label: "Safari", systemImage: "app"),
                    FilterTokenModel(id: "site", label: "example.com", systemImage: "globe"),
                ]
            )

            HStack(spacing: MemorySpacing.small) {
                CaptureStatusBadge(state: .paused)
                CaptureStatusBadge(state: .unavailable)
            }

            InlineErrorView(
                message: "Search could not finish; your query and filters were preserved.",
                diagnosticCode: "SEARCH-LOCAL-012"
            )

            ProgressStatusView(
                model: ProgressStatusModel(
                    label: "Adding visual matches…",
                    elapsedSeconds: 0.301,
                    completedFraction: 0.62
                )
            )
        }
    }

    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.medium) {
            MemoryResultCard(
                model: .fixture,
                state: .selected
            )
            EvidenceSnippet(
                model: EvidenceSnippetModel(
                    text: "yellow lamp near the window",
                    kind: .visual
                )
            )
        }
    }

    private var trustColumn: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.medium) {
            PermissionRow(
                title: "Accessibility",
                explanation: "Improves local text context and can be revoked in System Settings.",
                requirement: "Recommended",
                state: .denied
            )
            EmptyStateView(
                systemImage: "rectangle.stack",
                title: "No screen memory yet",
                message: "Your screen memory will appear here after recording begins.",
                actionTitle: "Check Capture Status"
            )
        }
    }
}

#Preview("LM-013 baseline board") {
    MemoryComponentBaselineBoard()
        .frame(
            width: MemorySnapshotSize.minimum.width,
            height: MemorySnapshotSize.minimum.height
        )
}
