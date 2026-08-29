import Foundation
import MemoryContracts

public enum MomentDetailError: Error, Equatable, Sendable {
    case sourceUnavailable
    case integrityMismatch
    case corruptMedia
    case manifestMismatch
    case invalidRaster
    case exportFailed
}

public struct MomentDetailRaster: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]

    public init(width: Int, height: Int, rgba8: [UInt8]) throws {
        guard width > 0, height > 0,
            width <= Int.max / height / 4,
            rgba8.count == width * height * 4
        else {
            throw MomentDetailError.invalidRaster
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }

    public var byteCount: Int { rgba8.count }
}

public struct MomentDetailIdentity: Hashable, Sendable {
    public let frameID: UUID
    public let locator: ContentLocator

    public init?(result: SearchResult) {
        guard case .archiveRelativePath = result.mediaLocator else { return nil }
        frameID = result.frameID
        locator = result.mediaLocator
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frameID == rhs.frameID && lhs.locator == rhs.locator
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameID)
        switch locator {
        case .archiveRelativePath(let value):
            hasher.combine(0)
            hasher.combine(value)
        case .opaqueResourceID(let value):
            hasher.combine(1)
            hasher.combine(value)
        }
    }
}

public struct MomentDetailFrame: Equatable, Sendable {
    public let identity: MomentDetailIdentity
    public let raster: MomentDetailRaster

    public init(identity: MomentDetailIdentity, raster: MomentDetailRaster) {
        self.identity = identity
        self.raster = raster
    }
}

public struct MomentDetailLoader: Sendable {
    private let operation: @Sendable (SearchResult) async throws -> MomentDetailRaster

    public init(operation: @escaping @Sendable (SearchResult) async throws -> MomentDetailRaster) {
        self.operation = operation
    }

    public func load(_ result: SearchResult) async throws -> MomentDetailRaster {
        try await operation(result)
    }
}

public struct MomentDetailValidator: Sendable {
    private let operation: @Sendable (SearchResult) async throws -> Void

    public init(operation: @escaping @Sendable (SearchResult) async throws -> Void) {
        self.operation = operation
    }

    public func validate(_ result: SearchResult) async throws {
        try await operation(result)
    }
}

public struct MomentExportPayload: Equatable, Sendable {
    public let frameID: UUID
    public let suggestedFilename: String
    public let heicData: Data
    public let packageRoot: URL?

    public init(
        frameID: UUID,
        suggestedFilename: String,
        heicData: Data,
        packageRoot: URL? = nil
    ) {
        self.frameID = frameID
        self.suggestedFilename = suggestedFilename
        self.heicData = heicData
        self.packageRoot = packageRoot
    }
}

public struct MomentExportProvider: Sendable {
    private let operation: @Sendable (SearchResult) async throws -> MomentExportPayload

    public init(
        operation: @escaping @Sendable (SearchResult) async throws -> MomentExportPayload
    ) {
        self.operation = operation
    }

    public func payload(for result: SearchResult) async throws -> MomentExportPayload {
        try await operation(result)
    }
}

public actor MomentDetailRepository {
    private let capacityBytes: Int
    private let validator: MomentDetailValidator?
    private let loader: MomentDetailLoader
    private var storage: [MomentDetailIdentity: MomentDetailRaster] = [:]
    private var recency: [MomentDetailIdentity] = []
    private var storedBytes = 0
    private var generation = 0

    public init(
        capacityBytes: Int,
        validator: MomentDetailValidator? = nil,
        loader: MomentDetailLoader
    ) {
        self.capacityBytes = max(1, capacityBytes)
        self.validator = validator
        self.loader = loader
    }

    public func frame(for result: SearchResult) async throws -> MomentDetailFrame? {
        guard let identity = MomentDetailIdentity(result: result) else {
            throw MomentDetailError.sourceUnavailable
        }
        generation += 1
        let requestGeneration = generation
        if let raster = storage[identity] {
            try await validator?.validate(result)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return nil }
            markRecent(identity)
            return MomentDetailFrame(identity: identity, raster: raster)
        }
        let raster = try await loader.load(result)
        try Task.checkCancellation()
        guard generation == requestGeneration else { return nil }
        insert(raster, identity: identity)
        return MomentDetailFrame(identity: identity, raster: raster)
    }

    public func cancelPending() {
        generation += 1
    }

    public func removeAll() {
        generation += 1
        storage.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        storedBytes = 0
    }

    public func cachedCount() -> Int { storage.count }

    private func insert(_ raster: MomentDetailRaster, identity: MomentDetailIdentity) {
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

    private func markRecent(_ identity: MomentDetailIdentity) {
        recency.removeAll { $0 == identity }
        recency.append(identity)
    }
}

public enum MomentDetailState: Equatable, Sendable {
    case idle
    case loading(frameID: UUID)
    case ready(MomentDetailFrame)
    case failure(frameID: UUID, reason: MomentDetailError)
}

public enum MomentDetailStepDirection: Equatable, Sendable {
    case previous
    case next
}

public struct MomentCanvasChromeProjection: Equatable, Sendable {
    public let applicationName: String
    public let timestamp: String
    public let canStepPrevious: Bool
    public let canStepNext: Bool
    public let isTransformed: Bool

    public init(
        applicationName: String,
        timestamp: String,
        canStepPrevious: Bool,
        canStepNext: Bool,
        isTransformed: Bool
    ) {
        self.applicationName = applicationName
        self.timestamp = timestamp
        self.canStepPrevious = canStepPrevious
        self.canStepNext = canStepNext
        self.isTransformed = isTransformed
    }

    public var accessibilityLabel: String {
        "\(applicationName), \(timestamp), previous moment "
            + "\(canStepPrevious ? "available" : "unavailable"), next moment "
            + "\(canStepNext ? "available" : "unavailable")"
    }
}

public enum MomentDetailSequence: Sendable {
    public static func adjacent(
        to frameID: UUID,
        direction: MomentDetailStepDirection,
        in results: [SearchResult]
    ) -> SearchResult? {
        guard let index = results.firstIndex(where: { $0.frameID == frameID }) else {
            return nil
        }
        let adjacentIndex = direction == .previous ? index - 1 : index + 1
        guard results.indices.contains(adjacentIndex) else { return nil }
        return results[adjacentIndex]
    }
}

public struct MomentCanvasTransform: Equatable, Sendable {
    public static let identity = MomentCanvasTransform(scale: 1, offsetX: 0, offsetY: 0)

    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(scale: Double, offsetX: Double, offsetY: Double) {
        self.scale = min(8, max(1, scale.isFinite ? scale : 1))
        self.offsetX = offsetX.isFinite ? offsetX : 0
        self.offsetY = offsetY.isFinite ? offsetY : 0
    }

    public func zoomed(to requestedScale: Double) -> Self {
        let boundedScale = min(8, max(1, requestedScale.isFinite ? requestedScale : 1))
        guard boundedScale > 1 else { return .identity }
        return Self(scale: boundedScale, offsetX: offsetX, offsetY: offsetY)
    }

    public func panned(
        byX deltaX: Double,
        y deltaY: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> Self {
        guard scale > 1, viewportWidth > 0, viewportHeight > 0 else { return .identity }
        let maximumX = viewportWidth * (scale - 1) / 2
        let maximumY = viewportHeight * (scale - 1) / 2
        return Self(
            scale: scale,
            offsetX: min(maximumX, max(-maximumX, offsetX + deltaX)),
            offsetY: min(maximumY, max(-maximumY, offsetY + deltaY))
        )
    }

    public func reset() -> Self { .identity }
}

@MainActor
public final class MomentDetailSessionModel: ObservableObject {
    @Published public private(set) var state: MomentDetailState = .idle

    private let repository: MomentDetailRepository
    private var generation = 0
    private var selectedResult: SearchResult?

    public init(repository: MomentDetailRepository) {
        self.repository = repository
    }

    public func select(_ result: SearchResult) async {
        selectedResult = result
        generation += 1
        let requestGeneration = generation
        state = .loading(frameID: result.frameID)
        do {
            let frame = try await repository.frame(for: result)
            guard generation == requestGeneration, let frame else { return }
            state = .ready(frame)
        } catch is CancellationError {
            return
        } catch let reason as MomentDetailError {
            guard generation == requestGeneration else { return }
            state = .failure(frameID: result.frameID, reason: reason)
        } catch {
            guard generation == requestGeneration else { return }
            state = .failure(frameID: result.frameID, reason: .sourceUnavailable)
        }
    }

    public func retry() async {
        guard let selectedResult else { return }
        await select(selectedResult)
    }

    public func clear() async {
        generation += 1
        selectedResult = nil
        await repository.cancelPending()
        state = .idle
    }
}
