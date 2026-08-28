# Local Storage, Data Model, and Lifecycle

## Outcome

Store a bounded rolling screen history locally without turning SQLite into a media blob, while preserving atomicity, deletability, migration safety, and predictable disk use.

## Storage layout

    ~/Library/Application Support/LocalMemory/
        database/
            archive.sqlite3
            archive.sqlite3-wal
            archive.sqlite3-shm
        media/
            YYYY/MM/DD/<chunk-id>/
                manifest.json
                frames/<frame-id>.heic
        thumbnails/
            YYYY/MM/DD/<frame-id>.heic
        audio/
            YYYY/MM/DD/<chunk-id>.m4a
        models/
        logs/
        vectors/
            mobileclip-s0/<model-hash>.f16
        quarantine/
        exports/

Set the root directory to mode 0700 and files to 0600 where applicable. Use relative paths in the database so the archive can move.

## Database

Use GRDB with SQLCipher-enabled SQLite in WAL mode. A DatabasePool serves reads; one DatabaseWriter actor serializes writes and coalesces hot-path inserts into short transactions. Use foreign keys and append-only migrations.

V1 logical tables are fixed by plan 10:

- media_chunks
- frames
- text_spans
- frame_fts
- artifacts
- vector_offsets
- activity_intervals
- policy_decisions
- access_policies
- deletion_tombstones
- processing_jobs
- audit_events
- archive_meta

Do not store source images, thumbnails, or vector matrices as SQLite blobs. The database holds metadata, logical presentation timestamps, exact source paths, offsets, and relative paths; the filesystem holds media and the rebuildable flat vector file.

## Canonical versus derived data

Canonical:

- Timestamp and app/window context
- Original approved foreground-window frames encoded as independent HEIC keyframes in single-epoch logical chunks of at most 30 seconds
- Accessibility extraction
- User rules and settings
- Optional original audio

Derived:

- OCR
- Searchable-frame thumbnails
- Embeddings
- Summaries
- Activity aggregates
- Search indexes

Derived data can always be rebuilt. Deleting a canonical record must cascade to every derivative.

## Media format

Use independent HEIC frame assets grouped by a canonical manifest from the first vertical slice. Each logical chunk belongs to exactly one approved window-capture epoch, has fixed encoded dimensions, lasts at most 30 seconds, and ends immediately on target-window, epoch, or dimension change. Each searchable frame records its epoch, target window, chunk, logical presentation timestamp, and exact source path; detail retrieval opens that independently decodable asset without video seeking.

The canonical manifest inventories ordered frame IDs, relative asset paths, logical times, byte counts, and SHA-256 digests. A hidden sibling directory is complete and validated before a no-replace atomic rename publishes it; only a subsequent database transaction makes it searchable.

Generate a 480-pixel HEIC thumbnail only for indexed searchable frames. Search and ordinary timeline browsing use thumbnails; detail and zoom decode the source chunk.

Persist at a maximum long edge of 1920 pixels while retaining original display dimensions and scale metadata. The baseline spike must verify that this resolution preserves OCR and visual retrieval quality.

## Retention and storage budgeting

Support both controls, with defaults of 30 days and 20 GB:

- Maximum age, such as 30, 90, 180 days, or forever
- Maximum disk budget, chosen from 5, 10, 20, or 50 GB

Cleanup order:

1. Remove expired temporary files.
2. Delete oldest complete HEIC logical chunk directories and their searchable frames when retention or hard budget requires it.
3. Do not preserve extracted text after its source media expires in V1; this keeps deletion semantics simple and honest.
4. Delete orphaned thumbnails, embeddings, indexes, and summaries.
5. Checkpoint and compact the database during idle time.

Make retention behavior visible before enabling it. Permanent deletion must not be described as compression.

## Deletion semantics

Support:

- Delete one result
- Delete a time range
- Delete all data from an application or site
- Forget the last 5, 15, or 60 minutes
- Delete all history

Deletion transaction:

1. Mark frame/chunk IDs with a deletion tombstone.
2. Remove them from query visibility immediately.
3. For a fully covered chunk, delete its directory. For a partial overlap, construct a replacement directory containing only retained independently encoded frames, verify every manifest digest, atomically swap database references, and dispose the old directory.
4. Delete all derived rows/files and commit database deletion.
5. Record a content-free local audit event.
6. Retry orphan cleanup if the filesystem operation failed.

Exports and external backups cannot be recalled; communicate this in the UI.

## Encryption

SQLCipher is required before personal dogfood:

- Generate a random 256-bit database key.
- Store it in macOS Keychain.
- Verify cipher activation on every database open.
- Ensure the app, CLI, and MCP helper share the same signed Keychain access.
- Test key loss and restore behavior explicitly.

HEIC source media and thumbnails rely on FileVault plus mode 0700/0600. They are not described as app-encrypted. Application-level media encryption is deferred; adding it requires an ADR and performance proof for exact-frame access, directory publication, and deletion replacement.

## Migrations and compatibility

- Every schema change is an append-only numbered migration.
- Never edit an applied migration.
- Back up the database before destructive migration.
- Migrations are resumable and covered by fixture upgrades from at least the previous two versions.
- Derived vectors include model and dimension identifiers, allowing coexistence during reindexing.
- Keep a read-only recovery/export command independent of the UI.

## Backup and export

No automatic cloud backup.

Provide an explicit export:

- Metadata and text as JSONL
- Media in timestamped directories
- A manifest with schema version and checksums
- Optional encrypted archive chosen by the user

Warn that Time Machine or third-party backup software may copy the local archive unless the user excludes it.

## Implementation phases

### S1: Schema and atomic write path

Gate: 100,000 synthetic captures ingest without corruption; kill tests leave no visible partial records.

### S2: HEIC keyframe media, searchable-frame index, and thumbnail store

Gate: random timeline access under 150 ms for a 30-day fixture.

### S3: Retention and deletion

Gate: deletion tests prove no result, file, vector, FTS row, summary, or thumbnail remains.

### S4: SQLCipher, export, and recovery

Gate: exported fixture round-trips and checksums match; SQLCipher activation and Keychain recovery are verified; corrupted-primary recovery is documented and tested.

## Reliability tests

- Process kill during media write, transaction, and cleanup
- Disk-full behavior
- Read-only filesystem
- Database lock contention
- Stale WAL recovery
- Interrupted migration
- Model-vector reindex
- Retention with clock changes
- Time Machine and external-volume path warnings

## Sources

- [SQLite WAL](https://www.sqlite.org/wal.html)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [GRDB](https://github.com/groue/GRDB.swift)
- [SQLCipher for Apple platforms](https://www.zetetic.net/sqlcipher/sqlcipher-apple/)
- [Screenpipe database implementation](https://github.com/screenpipe/screenpipe/blob/main/crates/screenpipe-db/src/db.rs)
- [Coast retention and local storage claims](https://coast.app/faq)
