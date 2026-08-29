import Foundation
import Security

public protocol AgentCapabilityKeyStoring: Sendable {
    func loadOrCreate() throws -> Data
}

public enum AgentCapabilityKeyError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
    case invalidKey
}

public struct SystemAgentCapabilityKeyStore: AgentCapabilityKeyStoring, Sendable {
    public static let accessGroup = "NS5L7NNR8U.com.justinhou.deepshelves.shared"
    public static let service = "com.justinhou.deepshelves.localmemory.agent-capability"
    public static let account = "primary-agent-capability-v1"

    public init() {}

    public func loadOrCreate() throws -> Data {
        switch fetch() {
        case .success(let key): return key
        case .failure(.keychain(errSecItemNotFound)):
            let key = try randomKey()
            let status = SecItemAdd(
                Self.query().merging([
                    kSecValueData as String: key,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]) { _, new in new } as CFDictionary,
                nil
            )
            if status == errSecDuplicateItem {
                return try fetch().get()
            }
            guard status == errSecSuccess else {
                throw AgentCapabilityKeyError.keychain(status)
            }
            return key
        case .failure(let error): throw error
        }
    }

    private func fetch() -> Result<Data, AgentCapabilityKeyError> {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.query().merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &result
        )
        guard status == errSecSuccess else {
            return .failure(.keychain(status))
        }
        guard let key = result as? Data, key.count == 32 else {
            return .failure(.invalidKey)
        }
        return .success(key)
    }

    private func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AgentCapabilityKeyError.randomGeneration(status)
        }
        return Data(bytes)
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public final class MemoryCapabilityKeyStore: AgentCapabilityKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let key: Data

    public init(key: Data) {
        self.key = key
    }

    public func loadOrCreate() throws -> Data {
        try lock.withLock {
            guard key.count == 32 else { throw AgentCapabilityKeyError.invalidKey }
            return key
        }
    }
}
