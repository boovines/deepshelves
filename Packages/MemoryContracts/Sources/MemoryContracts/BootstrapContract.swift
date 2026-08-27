import Foundation

public enum BootstrapContract {
    public static let schemaVersion = 1
}

public struct BootstrapStatus: Codable, Equatable, Sendable {
    public let component: String
    public let schemaVersion: Int
    public let state: String

    public init(component: String, schemaVersion: Int, state: String) {
        self.component = component
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

