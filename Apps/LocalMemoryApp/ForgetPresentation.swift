import MemoryDesignSystem
import MemorySearch
import SwiftUI

struct ForgetConfirmationFlow: View {
    @ObservedObject var model: ForgetSessionModel
    let onHidden: (Set<UUID>) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .confirming(let target):
                confirmation(target: target, isConfirming: false)
            case .requesting(let target):
                confirmation(target: target, isConfirming: true)
                ProgressView("Hiding selected moments…")
                    .accessibilityIdentifier("forget.requesting")
            case .processing(let operation):
                operationStatus(operation)
            case .complete(let operation):
                operationStatus(operation)
            case .failure(_, let diagnosticCode):
                failure(diagnosticCode: diagnosticCode)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .interactiveDismissDisabled(isRequesting)
        .accessibilityIdentifier("forget.flow")
    }

    private func confirmation(target: ForgetTarget, isConfirming: Bool) -> some View {
        DestructiveConfirmationSheet(
            model: DestructiveConfirmationModel(
                title: target.title,
                removalScope: target.removalScope,
                consequence:
                    "A verified rewrite of the affected short local chunk is queued. "
                    + "Existing exports or backups cannot be recalled.",
                confirmLabel: target.confirmLabel
            ),
            isConfirming: isConfirming,
            onCancel: {
                model.cancel()
                onDismiss()
            },
            onConfirm: {
                Task {
                    if let operation = await model.confirm() {
                        onHidden(operation.affectedFrameIDs)
                    }
                }
            }
        )
    }

    private func operationStatus(_ operation: ForgetOperation) -> some View {
        let projection = ForgetProgressProjection(operation: operation)
        return VStack(spacing: 16) {
            Label(
                projection.title,
                systemImage: operation.state == .complete
                    ? "checkmark.shield.fill" : "eye.slash.fill"
            )
            .font(.title2)
            Text(
                "The selected moments no longer appear in search, timeline, or agent access."
            )
            .multilineTextAlignment(.center)
            ProgressView(
                value: Double(projection.completedCount),
                total: Double(projection.totalCount)
            )
            .accessibilityLabel("Physical deletion progress")
            Text(projection.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Done") {
                model.dismissStatus()
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(projection.accessibilityLabel)
        .accessibilityIdentifier("forget.progress")
    }

    private func failure(diagnosticCode: String) -> some View {
        VStack(spacing: 16) {
            Label("Deletion needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
            Text(
                model.hiddenFrameIDs.isEmpty
                    ? "Nothing was hidden. You can safely try the request again."
                    : "The moments remain hidden. The verified physical rewrite will not be marked complete until it succeeds."
            )
            .multilineTextAlignment(.center)
            Text("Diagnostic: \(diagnosticCode)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") {
                    model.dismissStatus()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                if model.hiddenFrameIDs.isEmpty {
                    Button("Try Again") { model.retry() }
                }
            }
        }
        .accessibilityIdentifier("forget.failure")
    }

    private var isRequesting: Bool {
        if case .requesting = model.phase { return true }
        return false
    }
}

extension ForgetTarget {
    fileprivate var title: String {
        switch self {
        case .moment: "Forget this moment?"
        case .range: "Forget this time range?"
        }
    }

    fileprivate var removalScope: String {
        switch self {
        case .moment:
            "The selected moment will be hidden immediately from every local read surface."
        case .range(let interval):
            "Every moment from \(interval.start.formatted()) up to \(interval.end.formatted()) will be hidden immediately."
        }
    }

    fileprivate var confirmLabel: String {
        switch self {
        case .moment: "Forget Moment"
        case .range: "Forget Range"
        }
    }
}

extension ForgetOperationState {
    fileprivate var statusText: String {
        switch self {
        case .queued: "Verified physical rewrite queued."
        case .rewriting: "Rewriting the affected local chunk."
        case .verifying: "Verifying physical deletion."
        case .complete: "Physical deletion verified."
        case .failed: "Physical rewrite failed; the moments remain hidden."
        }
    }
}
