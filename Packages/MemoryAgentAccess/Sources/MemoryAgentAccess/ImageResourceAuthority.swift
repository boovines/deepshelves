import CryptoKit
import Foundation
import MemoryContracts

public enum ImageResourceError: Error, Equatable, Sendable {
    case invalidCapability
    case policyDenied
    case invalidResource
    case expired
    case notFound
    case boundsExceeded
    case integrityFailure
}

public struct ImageResourceHandle: Equatable, Sendable {
    public let resourceID: String
    public let expiresAt: Date

    public init(resourceID: String, expiresAt: Date) {
        self.resourceID = resourceID
        self.expiresAt = expiresAt
    }
}

public struct ImageResourceClaim: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let policyID: UUID
    public let expiresAt: Date

    public init(frameID: UUID, policyID: UUID, expiresAt: Date) {
        self.frameID = frameID
        self.policyID = policyID
        self.expiresAt = expiresAt
    }

    public func validate() throws {
        guard expiresAt.timeIntervalSince1970.isFinite else {
            throw ImageResourceError.invalidResource
        }
    }
}

public struct ImageResourceMetadata: Equatable, Sendable {
    public let frameID: UUID
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sha256: Data

    public init(frameID: UUID, width: Int, height: Int, byteCount: Int, sha256: Data) {
        self.frameID = frameID
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct BoundedImageResource: Equatable, Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let mediaType: String

    public init(data: Data, width: Int, height: Int, mediaType: String = "image/heic") {
        self.data = data
        self.width = width
        self.height = height
        self.mediaType = mediaType
    }
}

public struct ImageResourceAuthority: Sendable {
    public static let maximumLifetime: TimeInterval = 5 * 60

    private let key: SymmetricKey
    private let hasValidKeyLength: Bool
    private let now: @Sendable () -> Date

    public init(key: Data, now: @escaping @Sendable () -> Date = Date.init) {
        self.key = SymmetricKey(data: key)
        hasValidKeyLength = key.count == 32
        self.now = now
    }

    public func issue(frameID: UUID, policy: AccessPolicy) throws -> ImageResourceHandle {
        guard hasValidKeyLength else { throw ImageResourceError.invalidCapability }
        guard policy.allowImageResources, now() < policy.expiresAt else {
            throw ImageResourceError.policyDenied
        }
        let expiresAt = min(
            policy.expiresAt,
            now().addingTimeInterval(Self.maximumLifetime)
        )
        let claim = ImageResourceClaim(
            frameID: frameID,
            policyID: policy.id,
            expiresAt: expiresAt
        )
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(try ContractJSON.encode(claim), using: key)
        } catch {
            throw ImageResourceError.invalidCapability
        }
        guard let combined = sealed.combined else {
            throw ImageResourceError.invalidCapability
        }
        return ImageResourceHandle(
            resourceID: Self.base64URL(combined),
            expiresAt: expiresAt
        )
    }

    public func validate(resourceID: String) throws -> ImageResourceClaim {
        guard hasValidKeyLength else { throw ImageResourceError.invalidCapability }
        guard resourceID.count <= 2_048,
            let bytes = Self.decodeBase64URL(resourceID)
        else {
            throw ImageResourceError.invalidResource
        }
        let claim: ImageResourceClaim
        do {
            let box = try AES.GCM.SealedBox(combined: bytes)
            claim = try ContractJSON.decode(
                ImageResourceClaim.self,
                from: AES.GCM.open(box, using: key)
            )
        } catch {
            throw ImageResourceError.invalidResource
        }
        guard now() < claim.expiresAt else { throw ImageResourceError.expired }
        return claim
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            })
        else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

public enum BoundedImageResourceReader {
    public static let maximumDimension = 1_920
    public static let maximumBytes = 8 * 1_024 * 1_024

    public static func read(
        claim: ImageResourceClaim,
        metadata: ImageResourceMetadata,
        load: @escaping @Sendable () async throws -> Data
    ) async throws -> BoundedImageResource {
        try Task.checkCancellation()
        guard metadata.frameID == claim.frameID else { throw ImageResourceError.notFound }
        guard (1...maximumDimension).contains(metadata.width),
            (1...maximumDimension).contains(metadata.height),
            (1...maximumBytes).contains(metadata.byteCount)
        else {
            throw ImageResourceError.boundsExceeded
        }
        guard metadata.sha256.count == 32 else { throw ImageResourceError.integrityFailure }
        let data = try await load()
        try Task.checkCancellation()
        guard data.count == metadata.byteCount,
            Data(SHA256.hash(data: data)) == metadata.sha256
        else {
            throw ImageResourceError.integrityFailure
        }
        return BoundedImageResource(
            data: data,
            width: metadata.width,
            height: metadata.height
        )
    }
}
