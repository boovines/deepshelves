# Archive export, integrity, repair, and reset

This runbook covers the personal Local Memory archive. All operations are local. None of
the procedures downloads a model, contacts a service, or restores content from an
unverified source.

## Explicit selected-evidence export

1. The user explicitly selects one or more visible Moment identities and confirms export.
2. The export scope fixes a half-open time interval plus allowed application bundle IDs and
   approved browser hosts. A frame outside any bound fails the entire export.
3. The coordinator revalidates every frame as ready and unsuppressed, verifies its canonical
   HEIC-keyframe manifest and original-evidence SHA-256 without decoding it, and copies only
   the selected original bytes.
4. A hidden owner-only staging directory receives `metadata.jsonl`, timestamped
   `media/YYYY/MM/DD/<frame-id>.heic` evidence, and a schema-versioned `manifest.json` with
   every file's byte count and SHA-256. Publication is a single directory rename after a
   final serialized database-currentness check.
5. Existing exports and third-party backups are independent copies. Deleting the source
   archive cannot recall them.

Export failure removes the staging directory and leaves the archive unchanged. A corrupt,
missing, suppressed, deleted, unapproved, or concurrently changed source is never partially
published.

## Integrity check

Run the read-only integrity checker before repair or export when corruption is suspected. It
checks SQLCipher integrity, SQLite foreign keys, every database row marked as a ready HEIC
chunk, canonical manifest identity/inventory, and every original-evidence file's size and
SHA-256. Malformed ready rows are reported as failures rather than skipped. The report uses
content-free issue codes and stable chunk identities; it never copies captured text or pixels.

## Quarantine review

Review lists only top-level quarantine identity, reason, aggregate byte count, aggregate
SHA-256, and whether the item is a directory. It never renders, decodes, indexes, or returns
quarantined content. Symbolic links fail the review closed. Quarantine is not searchable.

## Archive repair

1. Stop capture and enrichment before invoking repair.
2. Run the same bounded recovery reconciler used at startup.
3. Orphan partials are removed. Orphan or integrity-invalid source items move to the
   owner-only quarantine. Their database rows and all search/derived projections are
   suppressed fail-closed, and dependent jobs are cancelled. Expired leases are requeued.
4. Run the integrity checker again and review quarantine.

Repair never manufactures a replacement frame, text span, vector, hash, or manifest. A
quarantined source stays suppressed until a future, separately specified recovery design can
prove an authentic source. Copying bytes out of quarantine and marking them ready manually is
not a supported repair.

## Missing or wrong Keychain key

The application must not generate a replacement key over an existing encrypted archive.
Capture remains stopped and the UI presents the unrecoverable-key state. If a verified
Keychain backup exists, restore the exact 256-bit key and retry open. Otherwise the only
supported recovery is the complete reset below; encrypted text cannot be reconstructed.

## Complete reset

1. Stop capture, enrichment, search helpers, and agent clients.
2. Read the native warning: the database, WAL, media, thumbnails, vectors, exports,
   quarantine, models, and local logs beneath this archive root are deleted. External exports
   and backups are not affected.
3. Type `DELETE LOCAL MEMORY ARCHIVE` exactly. Cancel is the default.
4. The reset coordinator validates the canonical archive location, atomically stages the
   root, deletes the shared Keychain key, removes staged bytes, and rolls both steps back when
   either deletion fails.
5. Relaunch. Only when the old root is absent may the key manager generate a fresh random
   256-bit key and initialize an empty archive. Run the integrity check before resuming capture.

Never delete only the Keychain key while retaining the archive root. That deliberately enters
the unrecoverable-key state and is not a secure whole-archive reset.

## Runtime validation boundary

The unit fixtures prove byte-exact selection, manifest/checksum validation, atomic
publication, content-free quarantine review, corrupt-source suppression, and fail-closed
repair without invoking a media decoder. The real application export/repair/reset/relaunch
journeys remain part of the unchanged H9 isolated-validation-Mac ledger; compile and fixture
evidence are not substitutes for those runtime checks.
