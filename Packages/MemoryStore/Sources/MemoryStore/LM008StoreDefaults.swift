import Foundation

public enum LM008StoreDefaults: Sendable {
    public static let keyByteCount = 32
    public static let journalMode = "WAL"
    public static let pageSize = 4_096
    public static let busyTimeoutMilliseconds = 5_000
    public static let maximumEncryptionOverheadFraction = 0.20
    public static let crashPointCount = 10_000
    public static let maximumReaderCount = 5
    public static let runtimeNetworkingAllowed = false
}
