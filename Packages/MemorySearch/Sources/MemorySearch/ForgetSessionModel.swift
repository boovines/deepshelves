import Combine
import Foundation

public enum ForgetTarget: Equatable, Sendable {
    case moment(UUID)
    case range(DateInterval)
}

public enum ForgetOperationState: String, Equatable, Sendable {
    case queued
    case rewriting
    case verifying
    case complete
    case failed
}

public struct ForgetOperation: Equatable, Sendable {
    public let id: UUID
    public let affectedFrameIDs: Set<UUID>
    public let state: ForgetOperationState
    public let completedRewriteCount: Int
    public let totalRewriteCount: Int
    public let failureCode: String?

    public init(
        id: UUID,
        affectedFrameIDs: Set<UUID>,
        state: ForgetOperationState,
        completedRewriteCount: Int,
        totalRewriteCount: Int,
        failureCode: String?
    ) {
        self.id = id
        self.affectedFrameIDs = affectedFrameIDs
        self.state = state
        self.completedRewriteCount = completedRewriteCount
        self.totalRewriteCount = totalRewriteCount
        self.failureCode = failureCode
    }
}

public struct ForgetProgressProjection: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let completedCount: Int
    public let totalCount: Int
    public let accessibilityLabel: String

    public init(operation: ForgetOperation) {
        completedCount = max(0, min(operation.completedRewriteCount, operation.totalRewriteCount))
        totalCount = max(1, operation.totalRewriteCount)
        switch operation.state {
        case .queued:
            title = "Hidden from memory"
            detail = "Verified physical deletion is queued."
        case .rewriting:
            title = "Hidden from memory"
            detail = "Rewriting affected local storage."
        case .verifying:
            title = "Hidden from memory"
            detail = "Verifying physical deletion."
        case .complete:
            title = "Deletion verified"
            detail = "Physical deletion is complete."
        case .failed:
            title = "Deletion needs attention"
            detail = "The moments remain hidden while physical deletion is unresolved."
        }
        accessibilityLabel =
            "\(title). \(detail) \(completedCount) of \(totalCount) rewrites complete."
    }
}

public struct MomentForgetProvider: Sendable {
    private let operation: @Sendable (ForgetTarget) async throws -> ForgetOperation

    public init(
        operation: @escaping @Sendable (ForgetTarget) async throws -> ForgetOperation
    ) {
        self.operation = operation
    }

    public func request(_ target: ForgetTarget) async throws -> ForgetOperation {
        try await operation(target)
    }
}

public enum ForgetSessionPhase: Equatable, Sendable {
    case idle
    case confirming(ForgetTarget)
    case requesting(ForgetTarget)
    case processing(ForgetOperation)
    case complete(ForgetOperation)
    case failure(target: ForgetTarget, diagnosticCode: String)
}

@MainActor
public final class ForgetSessionModel: ObservableObject {
    @Published public private(set) var phase: ForgetSessionPhase = .idle
    @Published public private(set) var hiddenFrameIDs: Set<UUID> = []

    public let cancelIsDefault = true

    private let provider: MomentForgetProvider

    public init(provider: MomentForgetProvider) {
        self.provider = provider
    }

    public func begin(_ target: ForgetTarget) {
        switch phase {
        case .requesting:
            return
        case .idle, .confirming, .processing, .complete, .failure:
            phase = .confirming(target)
        }
    }

    public func cancel() {
        guard case .requesting = phase else {
            phase = .idle
            return
        }
    }

    @discardableResult
    public func confirm() async -> ForgetOperation? {
        guard case .confirming(let target) = phase else { return nil }
        phase = .requesting(target)
        do {
            let operation = try await provider.request(target)
            hiddenFrameIDs.formUnion(operation.affectedFrameIDs)
            switch operation.state {
            case .queued, .rewriting, .verifying:
                phase = .processing(operation)
            case .complete:
                phase = .complete(operation)
            case .failed:
                phase = .failure(
                    target: target,
                    diagnosticCode: operation.failureCode ?? "LM-DELETE-REWRITE"
                )
            }
            return operation
        } catch is CancellationError {
            phase = .confirming(target)
            return nil
        } catch {
            phase = .failure(target: target, diagnosticCode: "LM-DELETE-REQUEST")
            return nil
        }
    }

    public func retry() {
        guard case .failure(let target, _) = phase, hiddenFrameIDs.isEmpty else { return }
        phase = .confirming(target)
    }

    public func dismissStatus() {
        guard case .requesting = phase else {
            phase = .idle
            return
        }
    }
}
