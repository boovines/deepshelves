import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable, ContractValidatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        try validate()
    }

    public func validate() throws {
        let values = [x, y, width, height]
        try ContractChecks.require(
            values.allSatisfy(\.isFinite),
            field: "normalizedRect",
            violation: .outOfRange,
            detail: "coordinates must be finite"
        )
        try ContractChecks.require(
            x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1,
            field: "normalizedRect",
            violation: .outOfRange,
            detail: "rectangle must fit within upper-left-origin normalized display coordinates"
        )
    }
}

public struct PixelSize: Codable, Equatable, Sendable, ContractValidatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            width > 0 && height > 0 && max(width, height) <= 1_920,
            field: "pixelSize",
            violation: .outOfRange,
            detail: "dimensions must be positive with a maximum long edge of 1920"
        )
    }
}

public struct ForegroundContext: Codable, Equatable, Sendable, ContractValidatable {
    public let bundleID: String
    public let applicationName: String
    public let processID: Int32?
    public let windowTitle: String?
    public let windowBounds: NormalizedRect

    public init(
        bundleID: String,
        applicationName: String,
        processID: Int32?,
        windowTitle: String?,
        windowBounds: NormalizedRect
    ) throws {
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.processID = processID
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            field: "foreground.bundleID",
            violation: .empty,
            detail: "bundle identifier is required"
        )
        try ContractChecks.require(
            !applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            field: "foreground.applicationName",
            violation: .empty,
            detail: "application name is required"
        )
        if let processID {
            try ContractChecks.require(
                processID > 0,
                field: "foreground.processID",
                violation: .outOfRange,
                detail: "process identifier must be positive"
            )
        }
        try windowBounds.validate()
    }
}

public enum BrowserFamily: String, Codable, Equatable, Sendable {
    case safari
    case chrome
    case edge
    case brave
    case arc
    case firefox
    case other
}

public struct BrowserOrigin: Codable, Equatable, Sendable, ContractValidatable {
    public let scheme: String
    public let host: String
    public let path: String?

    public init(scheme: String, host: String, path: String?) throws {
        self.scheme = scheme
        self.host = host
        self.path = path
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            !scheme.isEmpty && scheme == scheme.lowercased(),
            field: "browser.origin.scheme",
            violation: .inconsistent,
            detail: "scheme must be non-empty and lowercase"
        )
        try ContractChecks.require(
            !host.isEmpty && host == host.lowercased() && !host.contains("@"),
            field: "browser.origin.host",
            violation: .sensitiveURLComponent,
            detail: "host must be lowercase and contain no credential component"
        )
        if let path {
            try ContractChecks.require(
                path.hasPrefix("/") && !path.contains("?") && !path.contains("#")
                    && !path.contains("@"),
                field: "browser.origin.path",
                violation: .sensitiveURLComponent,
                detail:
                    "path must be absolute-within-origin and omit query, fragment, and credentials"
            )
        }
    }
}

public struct BrowserContext: Codable, Equatable, Sendable, ContractValidatable {
    public let family: BrowserFamily
    public let origin: BrowserOrigin
    public let isPrivateContext: Bool

    public init(family: BrowserFamily, origin: BrowserOrigin, isPrivateContext: Bool) throws {
        self.family = family
        self.origin = origin
        self.isPrivateContext = isPrivateContext
        try validate()
    }

    public func validate() throws {
        try origin.validate()
    }
}
