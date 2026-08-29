import Foundation
import MemoryContracts

public enum SearchThumbnailError: Error, Equatable, Sendable {
    case unavailable
    case invalidRaster
}

public struct SearchThumbnailRaster: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]

    public init(width: Int, height: Int, rgba8: [UInt8]) throws {
        guard width > 0, height > 0,
            width <= Int.max / height / 4,
            rgba8.count == width * height * 4
        else {
            throw SearchThumbnailError.invalidRaster
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }

    public var byteCount: Int { rgba8.count }
}

public struct SearchThumbnailIdentity: Hashable, Sendable {
    public enum LocatorKind: String, Hashable, Sendable {
        case archiveRelativePath
        case opaqueResourceID
    }

    public let frameID: UUID
    public let locatorKind: LocatorKind
    public let locatorValue: String

    public init?(result: SearchResult) {
        guard let locator = result.thumbnailLocator else { return nil }
        frameID = result.frameID
        switch locator {
        case .archiveRelativePath(let value):
            locatorKind = .archiveRelativePath
            locatorValue = value
        case .opaqueResourceID(let value):
            locatorKind = .opaqueResourceID
            locatorValue = value
        }
    }
}

public struct SearchThumbnailResponse: Equatable, Sendable {
    public let identity: SearchThumbnailIdentity
    public let raster: SearchThumbnailRaster

    public init(identity: SearchThumbnailIdentity, raster: SearchThumbnailRaster) {
        self.identity = identity
        self.raster = raster
    }
}

public struct SearchThumbnailLoader: Sendable {
    private let operation: @Sendable (SearchResult) async throws -> SearchThumbnailRaster

    public init(
        operation: @escaping @Sendable (SearchResult) async throws -> SearchThumbnailRaster
    ) {
        self.operation = operation
    }

    public func load(_ result: SearchResult) async throws -> SearchThumbnailRaster {
        try await operation(result)
    }
}

public struct SearchThumbnailValidator: Sendable {
    private let operation: @Sendable (SearchResult) async throws -> Void

    public init(operation: @escaping @Sendable (SearchResult) async throws -> Void) {
        self.operation = operation
    }

    public func validate(_ result: SearchResult) async throws {
        try await operation(result)
    }
}

public actor SearchThumbnailRepository {
    private let capacityBytes: Int
    private let validator: SearchThumbnailValidator?
    private let loader: SearchThumbnailLoader
    private var storage: [SearchThumbnailIdentity: SearchThumbnailRaster] = [:]
    private var recency: [SearchThumbnailIdentity] = []
    private var generations: [UUID: Int] = [:]
    private var storedBytes = 0

    public init(
        capacityBytes: Int,
        validator: SearchThumbnailValidator? = nil,
        loader: SearchThumbnailLoader
    ) {
        self.capacityBytes = max(1, capacityBytes)
        self.validator = validator
        self.loader = loader
    }

    public func thumbnail(for result: SearchResult) async throws -> SearchThumbnailResponse? {
        guard let identity = SearchThumbnailIdentity(result: result) else {
            throw SearchThumbnailError.unavailable
        }
        let generation = (generations[result.frameID] ?? 0) + 1
        generations[result.frameID] = generation
        if let cached = storage[identity] {
            do {
                try await validator?.validate(result)
            } catch {
                remove(identity)
                throw error
            }
            try Task.checkCancellation()
            guard generations[result.frameID] == generation else { return nil }
            markRecent(identity)
            return SearchThumbnailResponse(identity: identity, raster: cached)
        }

        let raster = try await loader.load(result)
        try await validator?.validate(result)
        try Task.checkCancellation()
        guard generations[result.frameID] == generation else { return nil }
        insert(raster, identity: identity)
        return SearchThumbnailResponse(identity: identity, raster: raster)
    }

    public func invalidate(frameID: UUID) {
        generations[frameID, default: 0] += 1
        let identities = storage.keys.filter { $0.frameID == frameID }
        for identity in identities {
            if let removed = storage.removeValue(forKey: identity) {
                storedBytes -= removed.byteCount
            }
            recency.removeAll { $0 == identity }
        }
    }

    public func removeAll() {
        storage.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        generations.removeAll(keepingCapacity: false)
        storedBytes = 0
    }

    public func cachedCount() -> Int { storage.count }

    private func insert(_ raster: SearchThumbnailRaster, identity: SearchThumbnailIdentity) {
        if let replaced = storage.updateValue(raster, forKey: identity) {
            storedBytes -= replaced.byteCount
        }
        storedBytes += raster.byteCount
        markRecent(identity)
        while storedBytes > capacityBytes, let oldest = recency.first {
            recency.removeFirst()
            if let removed = storage.removeValue(forKey: oldest) {
                storedBytes -= removed.byteCount
            }
        }
    }

    private func markRecent(_ identity: SearchThumbnailIdentity) {
        recency.removeAll { $0 == identity }
        recency.append(identity)
    }

    private func remove(_ identity: SearchThumbnailIdentity) {
        if let removed = storage.removeValue(forKey: identity) {
            storedBytes -= removed.byteCount
        }
        recency.removeAll { $0 == identity }
    }
}
