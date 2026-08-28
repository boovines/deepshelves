import Foundation
import ServiceManagement

public enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

public protocol LaunchAtLoginServicing: Sendable {
    func status() async -> LaunchAtLoginServiceStatus
    func register() async throws
    func unregister() async throws
}

public actor SystemLaunchAtLoginService: LaunchAtLoginServicing {
    public init() {}

    public func status() -> LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

public enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

public enum LaunchAtLoginHumanGate: String, Equatable, Sendable {
    case approveInLoginItems
}

public struct LaunchAtLoginSnapshot: Equatable, Sendable {
    public let status: LaunchAtLoginStatus
    public let humanGate: LaunchAtLoginHumanGate?

    public init(status: LaunchAtLoginStatus, humanGate: LaunchAtLoginHumanGate?) {
        self.status = status
        self.humanGate = humanGate
    }

    public var statusLabel: String {
        switch status {
        case .enabled: "Enabled"
        case .disabled: "Off"
        case .requiresApproval: "Approval required in Login Items"
        case .unavailable: "Unavailable"
        }
    }
}

public actor LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing
    private var snapshot = LaunchAtLoginSnapshot(status: .disabled, humanGate: nil)

    public init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
    }

    public func refresh() async -> LaunchAtLoginSnapshot {
        snapshot = await Self.project(service.status())
        return snapshot
    }

    public func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginSnapshot {
        let current = await service.status()
        if enabled, current != .enabled {
            try await service.register()
        } else if !enabled, current != .notRegistered {
            try await service.unregister()
        }
        return await refresh()
    }

    private static func project(
        _ status: LaunchAtLoginServiceStatus
    ) -> LaunchAtLoginSnapshot {
        switch status {
        case .enabled:
            LaunchAtLoginSnapshot(status: .enabled, humanGate: nil)
        case .notRegistered:
            LaunchAtLoginSnapshot(status: .disabled, humanGate: nil)
        case .requiresApproval:
            LaunchAtLoginSnapshot(status: .requiresApproval, humanGate: .approveInLoginItems)
        case .notFound:
            LaunchAtLoginSnapshot(status: .unavailable, humanGate: nil)
        }
    }
}
