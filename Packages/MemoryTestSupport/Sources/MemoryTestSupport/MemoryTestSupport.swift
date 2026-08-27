import Foundation

public enum MemoryTestSupport {
    public static func stableDate() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }
}

