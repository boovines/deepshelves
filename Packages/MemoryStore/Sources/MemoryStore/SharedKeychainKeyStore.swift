import Foundation
import Security

public enum SharedKeychainError: Error, Equatable, Sendable {
    case randomGeneration(OSStatus)
    case keychain(OSStatus)
    case invalidResult
}

public enum SharedKeychainKeyStore: Sendable {
    public static let accessGroup = "NS5L7NNR8U.com.justinhou.deepshelves.shared"
    public static let service = "com.justinhou.deepshelves.localmemory.archive-key"
    public static let archiveAccount = "primary-archive-v1"

    public static func generateAndStore(account: String) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: LM008StoreDefaults.keyByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw SharedKeychainError.randomGeneration(randomStatus)
        }
        let key = Data(bytes)
        try store(key, account: account)
        return key
    }

    public static func store(_ key: Data, account: String) throws {
        guard key.count == LM008StoreDefaults.keyByteCount else {
            throw SharedKeychainError.invalidResult
        }
        try delete(account: account, ignoreMissing: true)
        let status = SecItemAdd(
            baseQuery(account: account, accessGroup: accessGroup).merging([
                kSecValueData as String: key,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new } as CFDictionary,
            nil
        )
        guard status == errSecSuccess else {
            throw SharedKeychainError.keychain(status)
        }
    }

    public static func fetch(
        account: String,
        accessGroup: String = SharedKeychainKeyStore.accessGroup
    ) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(account: account, accessGroup: accessGroup).merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &result
        )
        guard status == errSecSuccess else {
            throw SharedKeychainError.keychain(status)
        }
        guard let data = result as? Data,
            data.count == LM008StoreDefaults.keyByteCount
        else {
            throw SharedKeychainError.invalidResult
        }
        return data
    }

    public static func statusForFetch(account: String, accessGroup: String) -> OSStatus {
        var result: CFTypeRef?
        return SecItemCopyMatching(
            baseQuery(account: account, accessGroup: accessGroup).merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &result
        )
    }

    public static func delete(account: String, ignoreMissing: Bool = false) throws {
        let status = SecItemDelete(
            baseQuery(account: account, accessGroup: accessGroup) as CFDictionary
        )
        guard status == errSecSuccess || (ignoreMissing && status == errSecItemNotFound) else {
            throw SharedKeychainError.keychain(status)
        }
    }

    private static func baseQuery(account: String, accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
