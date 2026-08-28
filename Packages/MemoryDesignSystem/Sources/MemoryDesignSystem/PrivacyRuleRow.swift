import SwiftUI

public struct PrivacyRuleRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let precedence: Int
    public let actionLabel: String

    public init(
        id: String,
        title: String,
        detail: String,
        precedence: Int,
        actionLabel: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.precedence = precedence
        self.actionLabel = actionLabel
    }
}

public struct PrivacyRuleRow: View {
    private let model: PrivacyRuleRowModel
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private let moveUp: () -> Void
    private let moveDown: () -> Void
    private let remove: () -> Void

    public init(
        model: PrivacyRuleRowModel,
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        self.model = model
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.remove = remove
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.body)
                    .lineLimit(1)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text("#\(model.precedence)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Precedence \(model.precedence)")

            HStack(spacing: 4) {
                Button(action: moveUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("Move rule earlier")
                .accessibilityLabel("Move \(model.title) earlier")
                .accessibilityIdentifier("privacy.rule.\(model.id).moveEarlier")

                Button(action: moveDown) {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("Move rule later; later matching rules take precedence")
                .accessibilityLabel("Move \(model.title) later")
                .accessibilityIdentifier("privacy.rule.\(model.id).moveLater")

                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle")
                }
                .help("Remove privacy rule")
                .accessibilityLabel("Remove \(model.title)")
                .accessibilityIdentifier("privacy.rule.\(model.id).remove")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(model.title), \(model.detail), precedence \(model.precedence), "
                + model.actionLabel
        )
        .accessibilityIdentifier("privacy.rule.\(model.id)")
    }
}

#Preview("Privacy rule") {
    PrivacyRuleRow(
        model: PrivacyRuleRowModel(
            id: "preview-rule",
            title: "Block com.example.private-notes",
            detail: "Application · Last matching user rule wins",
            precedence: 2,
            actionLabel: "Blocked"
        ),
        canMoveUp: true,
        canMoveDown: false,
        moveUp: {},
        moveDown: {},
        remove: {}
    )
    .padding()
    .frame(width: 620)
}

#Preview("Privacy rule, long text") {
    PrivacyRuleRow(
        model: PrivacyRuleRowModel(
            id: "preview-long-rule",
            title: "Block a deliberately long localized application identifier",
            detail: "Application exclusion applied locally and immediately after saving",
            precedence: 12,
            actionLabel: "Blocked"
        ),
        canMoveUp: true,
        canMoveDown: true,
        moveUp: {},
        moveDown: {},
        remove: {}
    )
    .padding()
    .frame(width: 620)
}
