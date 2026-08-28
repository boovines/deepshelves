import Foundation
import GRDB
import MemoryContracts

public enum ArchiveVisualSearchStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidProjection
    case duplicateProjection
}

public struct ArchiveVisualProjection: Equatable, Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let foreground: ForegroundContext
    public let browser: BrowserContext?
    public let mediaPath: ArchiveRelativePath
    public let thumbnailPath: ArchiveRelativePath?

    public init(
        frameID: UUID,
        capturedAt: Date,
        foreground: ForegroundContext,
        browser: BrowserContext?,
        mediaPath: ArchiveRelativePath,
        thumbnailPath: ArchiveRelativePath?
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.foreground = foreground
        self.browser = browser
        self.mediaPath = mediaPath
        self.thumbnailPath = thumbnailPath
    }
}

public final class ArchiveVisualSearchStore: @unchecked Sendable {
    private let archive: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        archive = database
    }

    public func projections(
        frameIDs: [UUID],
        modelHash: Data,
        filter: ArchiveVectorScanFilter
    ) throws -> [UUID: ArchiveVisualProjection] {
        guard !frameIDs.isEmpty, frameIDs.count <= 100, Set(frameIDs).count == frameIDs.count,
            modelHash.count == 32
        else {
            if frameIDs.isEmpty { return [:] }
            throw ArchiveVisualSearchStoreError.invalidRequest
        }
        return try archive.atomicRead { database in
            var predicates = [
                "frames.id IN (\(Self.placeholders(frameIDs.count)))",
                "frames.visual_state = 'ready'",
                "media_chunks.state = 'ready'",
                "offsets.state = 'ready'",
                "offsets.model_hash = ?",
                "EXISTS (SELECT 1 FROM artifacts vectors WHERE vectors.frame_id = frames.id AND vectors.kind = 'visualVector' AND vectors.model_hash = offsets.model_hash AND vectors.state = 'ready')",
            ]
            var arguments: [DatabaseValueConvertible?] = frameIDs.map {
                $0.uuidString.lowercased()
            }
            arguments.append(modelHash.map { String(format: "%02x", $0) }.joined())
            if let interval = filter.capturedAt {
                predicates.append("frames.captured_at >= ? AND frames.captured_at < ?")
                arguments.append(Self.encode(interval.lowerBound))
                arguments.append(Self.encode(interval.upperBound))
            }
            if !filter.bundleIdentifiers.isEmpty {
                predicates.append(
                    "frames.bundle_id IN (\(Self.placeholders(filter.bundleIdentifiers.count)))"
                )
                arguments.append(contentsOf: filter.bundleIdentifiers.sorted())
            }
            if let allowedHosts = filter.allowedHosts {
                if allowedHosts.isEmpty {
                    predicates.append("frames.url_host IS NULL")
                } else {
                    predicates.append(
                        "(frames.url_host IS NULL OR frames.url_host IN (\(Self.placeholders(allowedHosts.count))))"
                    )
                    arguments.append(contentsOf: allowedHosts.sorted())
                }
            }
            if !filter.hosts.isEmpty {
                predicates.append("frames.url_host IN (\(Self.placeholders(filter.hosts.count)))")
                arguments.append(contentsOf: filter.hosts.sorted())
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT frames.id, frames.captured_at, frames.bundle_id, frames.app_name,
                           frames.window_title, frames.window_x, frames.window_y,
                           frames.window_w, frames.window_h, frames.browser_family,
                           frames.url_scheme, frames.url_host, frames.url_path,
                           frames.media_path,
                           CASE WHEN EXISTS (
                               SELECT 1 FROM artifacts thumbnails
                               WHERE thumbnails.frame_id = frames.id
                                 AND thumbnails.kind = 'thumbnail'
                                 AND thumbnails.state = 'ready'
                           ) THEN frames.thumbnail_path ELSE NULL END AS thumbnail_path
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    JOIN vector_offsets offsets ON offsets.frame_id = frames.id
                    WHERE \(predicates.joined(separator: " AND "))
                    ORDER BY frames.id
                    """,
                arguments: StatementArguments(arguments)
            )
            var projections: [UUID: ArchiveVisualProjection] = [:]
            for row in rows {
                let projection = try Self.projection(row)
                guard projections.updateValue(projection, forKey: projection.frameID) == nil else {
                    throw ArchiveVisualSearchStoreError.duplicateProjection
                }
            }
            return projections
        }
    }

    private static func projection(_ row: Row) throws -> ArchiveVisualProjection {
        let encodedFrameID: String = row["id"]
        let encodedCapturedAt: String = row["captured_at"]
        let bundleID: String? = row["bundle_id"]
        let applicationName: String? = row["app_name"]
        let mediaPath: String? = row["media_path"]
        let windowX: Double? = row["window_x"]
        let windowY: Double? = row["window_y"]
        let windowWidth: Double? = row["window_w"]
        let windowHeight: Double? = row["window_h"]
        guard let frameID = UUID(uuidString: encodedFrameID),
            let capturedAt = decode(encodedCapturedAt),
            let bundleID,
            let applicationName,
            let mediaPath,
            let windowX,
            let windowY,
            let windowWidth,
            let windowHeight
        else {
            throw ArchiveVisualSearchStoreError.invalidProjection
        }
        let foreground = try ForegroundContext(
            bundleID: bundleID,
            applicationName: applicationName,
            processID: nil,
            windowTitle: row["window_title"],
            windowBounds: NormalizedRect(
                x: windowX,
                y: windowY,
                width: windowWidth,
                height: windowHeight
            )
        )
        let host: String? = row["url_host"]
        let family: String? = row["browser_family"]
        let scheme: String? = row["url_scheme"]
        let path: String? = row["url_path"]
        let browser: BrowserContext?
        if let host {
            guard let family, let browserFamily = BrowserFamily(rawValue: family), let scheme else {
                throw ArchiveVisualSearchStoreError.invalidProjection
            }
            browser = try BrowserContext(
                family: browserFamily,
                origin: BrowserOrigin(scheme: scheme, host: host, path: path),
                isPrivateContext: false
            )
        } else {
            guard family == nil, scheme == nil, path == nil else {
                throw ArchiveVisualSearchStoreError.invalidProjection
            }
            browser = nil
        }
        let encodedThumbnail: String? = row["thumbnail_path"]
        return try ArchiveVisualProjection(
            frameID: frameID,
            capturedAt: capturedAt,
            foreground: foreground,
            browser: browser,
            mediaPath: ArchiveRelativePath(mediaPath),
            thumbnailPath: encodedThumbnail.map(ArchiveRelativePath.init)
        )
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func decode(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }
}
