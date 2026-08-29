import Foundation
import MemoryAgentAccess
import MemoryStore

enum SignedImageResourceComposition {
    static func makeBackend(database: ArchiveDatabase?) -> LocalMemoryMCPImageBackend? {
        guard let database,
            let root = database.paths?.root,
            let fileStore = database.fileStore
        else {
            return nil
        }
        let policyStore = AccessPolicyStore(
            fileURL: root.appending(path: "agent-access/policies-v1.json")
        )
        return LocalMemoryMCPImageBackend(
            issue: { frameID, policyID in
                do {
                    let capability = try await policyStore.localCapability()
                    return try await policyStore.withAuthorizedPolicy(
                        id: policyID,
                        capability: capability
                    ) { policy in
                        guard policy.allowImageResources,
                            try SignedCLIEntrypoint.findMoment(
                                frameID,
                                policy: policy,
                                database: database
                            ) != nil
                        else {
                            throw ImageResourceError.policyDenied
                        }
                        let source = try ArchiveMomentSourceStore(database: database)
                            .readySource(frameID: frameID)
                        try validateBounds(source)
                        let handle = try ImageResourceAuthority(key: capability)
                            .issue(frameID: frameID, policy: policy)
                        return MCPImageResourceIssue(
                            resourceID: handle.resourceID,
                            expiresAt: handle.expiresAt
                        )
                    }
                } catch {
                    throw map(error)
                }
            },
            read: { resourceID in
                do {
                    let capability = try await policyStore.localCapability()
                    let claim = try ImageResourceAuthority(key: capability)
                        .validate(resourceID: resourceID)
                    return try await policyStore.withAuthorizedPolicy(
                        id: claim.policyID,
                        capability: capability
                    ) { policy in
                        guard policy.allowImageResources,
                            claim.expiresAt <= policy.expiresAt,
                            try SignedCLIEntrypoint.findMoment(
                                claim.frameID,
                                policy: policy,
                                database: database
                            ) != nil
                        else {
                            throw ImageResourceError.policyDenied
                        }
                        let source = try ArchiveMomentSourceStore(database: database)
                            .readySource(frameID: claim.frameID)
                        try validateBounds(source)
                        return try await BoundedImageResourceReader.read(
                            claim: claim,
                            metadata: ImageResourceMetadata(
                                frameID: source.frameID,
                                width: source.width,
                                height: source.height,
                                byteCount: source.mediaByteCount,
                                sha256: source.mediaHash
                            ),
                            load: {
                                try Task.checkCancellation()
                                return try Data(contentsOf: fileStore.url(for: source.mediaPath))
                            }
                        )
                    }
                } catch {
                    throw map(error)
                }
            }
        )
    }

    private static func validateBounds(_ source: ArchiveMomentSourceRecord) throws {
        guard source.width <= BoundedImageResourceReader.maximumDimension,
            source.height <= BoundedImageResourceReader.maximumDimension,
            source.mediaByteCount <= BoundedImageResourceReader.maximumBytes
        else {
            throw ImageResourceError.boundsExceeded
        }
    }

    private static func map(_ error: Error) -> Error {
        if error is CancellationError || error is ImageResourceError { return error }
        switch error as? AgentAccessPolicyError {
        case .expired: return ImageResourceError.expired
        case .notFound, .revoked: return ImageResourceError.notFound
        case .invalidCapability: return ImageResourceError.policyDenied
        case .corruptStore, .unsafePath: return ImageResourceError.integrityFailure
        case .duplicatePolicy, .none: return ImageResourceError.notFound
        }
    }
}
