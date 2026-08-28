import SwiftUI

public struct MemorySearchField: View {
    @Binding private var text: String
    @FocusState private var isFocused: Bool

    private let model: MemorySearchFieldModel
    private let onSubmit: () -> Void
    private let onEscape: () -> Void

    public init(
        text: Binding<String>,
        model: MemorySearchFieldModel,
        onSubmit: @escaping () -> Void = {},
        onEscape: @escaping () -> Void = {}
    ) {
        _text = text
        self.model = model
        self.onSubmit = onSubmit
        self.onEscape = onEscape
    }

    public var body: some View {
        MemoryTokenReader { environment in
            HStack(spacing: MemorySpacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
                    .accessibilityHidden(true)

                TextField(model.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(MemoryTypeToken.body.font)
                    .focused($isFocused)
                    .onSubmit(onSubmit)
                    .accessibilityLabel("Search screen memory")

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
                    .frame(minWidth: MemoryControlHeight.compact, minHeight: MemoryControlHeight.compact)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }

                if model.state == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Search in progress")
                }
            }
            .padding(.horizontal, MemorySpacing.medium)
            .frame(minHeight: MemoryControlHeight.searchField)
            .background(
                MemoryColorToken.surfaceControl.color,
                in: RoundedRectangle(cornerRadius: MemoryRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MemoryRadius.control)
                    .stroke(
                        borderColor,
                        lineWidth: environment.hairlineWidth
                    )
            }
            .opacity(model.state == .disabled ? 0.55 : 1)
            .disabled(model.state == .disabled)
            .onAppear {
                if model.isInitiallyFocused || model.state == .focused {
                    isFocused = true
                }
            }
            .onExitCommand(perform: onEscape)
        }
    }

    private var borderColor: Color {
        if model.state == .error {
            return MemoryColorToken.statusPaused.color
        }
        if isFocused || model.state == .focused {
            return MemoryColorToken.accent.color
        }
        return MemoryColorToken.borderDefault.color
    }
}

public struct FilterToken: View {
    public let model: FilterTokenModel
    public let state: MemoryComponentInteractionState
    public let onActivate: () -> Void

    public init(
        model: FilterTokenModel,
        state: MemoryComponentInteractionState = .normal,
        onActivate: @escaping () -> Void = {}
    ) {
        self.model = model
        self.state = state
        self.onActivate = onActivate
    }

    public var body: some View {
        MemoryTokenReader { environment in
            Button(action: onActivate) {
                HStack(spacing: MemorySpacing.xSmall) {
                    if let systemImage = model.systemImage {
                        Image(systemName: systemImage)
                            .accessibilityHidden(true)
                    }
                    Text(model.label)
                        .lineLimit(1)
                    if model.isRemovable {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                }
                .font(MemoryTypeToken.caption.font)
                .padding(.horizontal, MemorySpacing.small)
                .frame(minHeight: MemoryControlHeight.compact)
                .background(
                    backgroundColor(environment: environment),
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(
                        state == .focused
                            ? MemoryColorToken.accent.color
                            : MemoryColorToken.borderDefault.color,
                        lineWidth: environment.hairlineWidth
                    )
                }
            }
            .buttonStyle(.plain)
            .disabled(state == .disabled)
            .opacity(state == .disabled ? 0.55 : 1)
            .accessibilityLabel(model.isRemovable ? "Remove filter \(model.label)" : model.label)
            .help(model.isRemovable ? "Remove \(model.label) filter" : model.label)
        }
    }

    private func backgroundColor(environment: MemoryTokenEnvironment) -> Color {
        if model.isSelected || state == .selected || state == .pressed {
            return MemoryColorToken.surfaceSelected.color(contrast: environment.contrast)
        }
        return MemoryColorToken.surfaceControl.color
    }
}

public struct FilterTokenBar: View {
    public let tokens: [FilterTokenModel]
    public let state: MemoryComponentInteractionState
    public let onActivate: (FilterTokenModel) -> Void

    public init(
        tokens: [FilterTokenModel],
        state: MemoryComponentInteractionState = .normal,
        onActivate: @escaping (FilterTokenModel) -> Void = { _ in }
    ) {
        self.tokens = tokens
        self.state = state
        self.onActivate = onActivate
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MemorySpacing.small) {
                ForEach(tokens) { token in
                    FilterToken(model: token, state: state) {
                        onActivate(token)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active search filters")
    }
}

public struct CaptureStatusBadge: View {
    public let state: CaptureStatusState

    public init(state: CaptureStatusState) {
        self.state = state
    }

    public var body: some View {
        let presentation = state.presentation
        HStack(spacing: MemorySpacing.xSmall) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.colorToken.color)
                .accessibilityHidden(true)
            Text(presentation.label)
                .foregroundStyle(MemoryColorToken.textPrimary.color)
        }
        .font(MemoryTypeToken.caption.font)
        .padding(.horizontal, MemorySpacing.small)
        .frame(minHeight: MemoryControlHeight.compact)
        .background(
            MemoryColorToken.surfaceControl.color,
            in: Capsule()
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

public struct EvidenceSnippet: View {
    public let model: EvidenceSnippetModel
    public let state: MemoryComponentInteractionState

    public init(
        model: EvidenceSnippetModel,
        state: MemoryComponentInteractionState = .normal
    ) {
        self.model = model
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.xSmall) {
            Text(model.kind.rawValue)
                .font(MemoryTypeToken.caption.font)
                .foregroundStyle(MemoryColorToken.textTertiary.color)
            Text(model.text)
                .font(MemoryTypeToken.callout.font)
                .foregroundStyle(state == .error
                    ? MemoryColorToken.statusPaused.color
                    : MemoryColorToken.textSecondary.color)
                .lineLimit(model.lineLimit)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.kind.rawValue): \(model.text)")
    }
}

public struct MemoryResultCard: View {
    public let model: MemoryResultCardModel
    public let state: MemoryComponentInteractionState
    public let onOpen: () -> Void

    public init(
        model: MemoryResultCardModel,
        state: MemoryComponentInteractionState = .normal,
        onOpen: @escaping () -> Void = {}
    ) {
        self.model = model
        self.state = state
        self.onOpen = onOpen
    }

    public var body: some View {
        MemoryTokenReader { environment in
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: MemorySpacing.small) {
                    ZStack {
                        MemoryColorToken.surfaceSidebar.color
                        Image(systemName: model.thumbnailSystemImage)
                            .font(MemoryTypeToken.title2.font)
                            .foregroundStyle(MemoryColorToken.textTertiary.color)
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: MemoryRadius.control))

                    Text(model.title)
                        .font(MemoryTypeToken.headline.font)
                        .foregroundStyle(MemoryColorToken.textPrimary.color)
                        .lineLimit(model.titleLineLimit)

                    HStack(spacing: MemorySpacing.small) {
                        Text(model.timeText)
                            .font(MemoryTypeToken.timecode.font)
                        Text(model.appName)
                        if let host = model.host {
                            Text(host)
                                .lineLimit(1)
                        }
                    }
                    .font(MemoryTypeToken.caption.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)

                    EvidenceSnippet(model: model.evidence, state: state)
                }
                .padding(MemorySpacing.medium)
                .background(
                    cardBackground(environment: environment),
                    in: RoundedRectangle(cornerRadius: MemoryRadius.card)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MemoryRadius.card)
                        .stroke(
                            state == .focused
                                ? MemoryColorToken.accent.color
                                : MemoryColorToken.borderDefault.color,
                            lineWidth: environment.hairlineWidth
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(state == .disabled || state == .loading)
            .opacity(state == .disabled ? 0.55 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint("Press Return to open detail; press Space to preview")
        }
    }

    private func cardBackground(environment: MemoryTokenEnvironment) -> Color {
        if state == .selected || state == .pressed {
            return MemoryColorToken.surfaceSelected.color(contrast: environment.contrast)
        }
        return MemoryColorToken.surfaceControl.color
    }
}

public struct PermissionRow: View {
    public let title: String
    public let explanation: String
    public let requirement: String
    public let state: PermissionState
    public let interactionState: MemoryComponentInteractionState
    public let onAction: () -> Void

    public init(
        title: String,
        explanation: String,
        requirement: String,
        state: PermissionState,
        interactionState: MemoryComponentInteractionState = .normal,
        onAction: @escaping () -> Void = {}
    ) {
        self.title = title
        self.explanation = explanation
        self.requirement = requirement
        self.state = state
        self.interactionState = interactionState
        self.onAction = onAction
    }

    public var body: some View {
        let presentation = state.presentation
        HStack(alignment: .top, spacing: MemorySpacing.medium) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.colorToken.color)
                .frame(width: MemoryControlHeight.compact, height: MemoryControlHeight.compact)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MemorySpacing.xSmall) {
                HStack {
                    Text(title)
                        .font(MemoryTypeToken.headline.font)
                    Text(requirement)
                        .font(MemoryTypeToken.caption.font)
                        .foregroundStyle(MemoryColorToken.textSecondary.color)
                }
                Text(explanation)
                    .font(MemoryTypeToken.callout.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(presentation.label)
                    .font(MemoryTypeToken.caption.font)
                    .foregroundStyle(presentation.colorToken.color)
            }

            Spacer(minLength: MemorySpacing.medium)

            if let actionTitle = presentation.actionTitle {
                Button(actionTitle, action: onAction)
                    .frame(minHeight: MemoryControlHeight.standard)
                    .disabled(interactionState == .disabled)
            }
        }
        .padding(MemorySpacing.medium)
        .background(
            MemoryColorToken.surfaceControl.color,
            in: RoundedRectangle(cornerRadius: MemoryRadius.card)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(requirement), \(presentation.label)")
    }
}

public struct EmptyStateView: View {
    public let systemImage: String
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let onAction: () -> Void

    public init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        onAction: @escaping () -> Void = {}
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: MemorySpacing.medium) {
            Image(systemName: systemImage)
                .font(MemoryTypeToken.title2.font)
                .foregroundStyle(MemoryColorToken.textTertiary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(MemoryTypeToken.headline.font)
            Text(message)
                .font(MemoryTypeToken.callout.font)
                .foregroundStyle(MemoryColorToken.textSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .frame(minHeight: MemoryControlHeight.standard)
            }
        }
        .padding(MemorySpacing.xLarge)
        .accessibilityElement(children: .contain)
    }
}

public struct InlineErrorView: View {
    public let message: String
    public let diagnosticCode: String?
    public let retryTitle: String?
    public let onRetry: () -> Void

    public init(
        message: String,
        diagnosticCode: String? = nil,
        retryTitle: String? = "Try Again",
        onRetry: @escaping () -> Void = {}
    ) {
        self.message = message
        self.diagnosticCode = diagnosticCode
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .top, spacing: MemorySpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MemoryColorToken.statusPaused.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MemorySpacing.xSmall) {
                Text(message)
                    .font(MemoryTypeToken.callout.font)
                if let diagnosticCode {
                    Text("Diagnostic code: \(diagnosticCode)")
                        .font(MemoryTypeToken.caption.font)
                        .foregroundStyle(MemoryColorToken.textSecondary.color)
                }
            }
            Spacer(minLength: MemorySpacing.small)
            if let retryTitle {
                Button(retryTitle, action: onRetry)
                    .frame(minHeight: MemoryControlHeight.compact)
            }
        }
        .padding(MemorySpacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(diagnosticCode.map { "\(message), diagnostic code \($0)" } ?? message)
    }
}

public struct ProgressStatusView: View {
    public let model: ProgressStatusModel

    public init(model: ProgressStatusModel) {
        self.model = model
    }

    public var body: some View {
        if model.showsIndicator {
            HStack(spacing: MemorySpacing.small) {
                if let completedFraction = model.completedFraction {
                    ProgressView(value: completedFraction)
                        .frame(maxWidth: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.label)
                    .font(MemoryTypeToken.callout.font)
                    .foregroundStyle(MemoryColorToken.textSecondary.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.label)
        }
    }
}

public struct DestructiveConfirmationSheet: View {
    public let model: DestructiveConfirmationModel
    public let isConfirming: Bool
    public let onCancel: () -> Void
    public let onConfirm: () -> Void

    public init(
        model: DestructiveConfirmationModel,
        isConfirming: Bool = false,
        onCancel: @escaping () -> Void = {},
        onConfirm: @escaping () -> Void = {}
    ) {
        self.model = model
        self.isConfirming = isConfirming
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MemorySpacing.large) {
            HStack(alignment: .top, spacing: MemorySpacing.medium) {
                Image(systemName: "trash.fill")
                    .font(MemoryTypeToken.title2.font)
                    .foregroundStyle(MemoryColorToken.textPrimary.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MemorySpacing.small) {
                    Text(model.title)
                        .font(MemoryTypeToken.title2.font)
                    Text(model.removalScope)
                        .font(MemoryTypeToken.body.font)
                    Text(model.consequence)
                        .font(MemoryTypeToken.callout.font)
                        .foregroundStyle(MemoryColorToken.textSecondary.color)
                }
            }

            HStack {
                Spacer()
                Button(model.cancelLabel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(minHeight: MemoryControlHeight.standard)
                Button(model.confirmLabel, role: .destructive, action: onConfirm)
                    .disabled(isConfirming)
                    .frame(minHeight: MemoryControlHeight.standard)
            }
        }
        .padding(MemorySpacing.xLarge)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
    }
}
