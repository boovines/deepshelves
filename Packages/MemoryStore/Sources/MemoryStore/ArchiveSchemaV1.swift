import GRDB

enum ArchiveSchemaV1 {
    static let migrationIdentifier = "v1_archive_schema"

    static let logicalTableNames: Set<String> = [
        "access_policies",
        "activity_intervals",
        "archive_meta",
        "artifacts",
        "audit_events",
        "deletion_tombstones",
        "frame_fts",
        "frames",
        "media_chunks",
        "policy_decisions",
        "processing_jobs",
        "text_spans",
        "vector_offsets",
    ]

    static func migrator(
        afterV1Schema: (@Sendable () throws -> Void)? = nil
    ) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            migrationIdentifier,
            foreignKeyChecks: .immediate
        ) { database in
            for statement in statements {
                try database.execute(sql: statement)
            }
            try database.execute(
                sql: "INSERT INTO archive_meta(key, value) VALUES (?, ?)",
                arguments: ["schema_version", "1"]
            )
            try database.execute(
                sql: "INSERT INTO archive_meta(key, value) VALUES (?, ?)",
                arguments: ["contract_version", "1"]
            )
            try afterV1Schema?()
        }
        return migrator
    }

    private static let statements = [
        """
        CREATE TABLE archive_meta (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE media_chunks (
            id TEXT NOT NULL PRIMARY KEY,
            capture_epoch_id TEXT NOT NULL,
            target_window_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL UNIQUE,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            codec TEXT NOT NULL,
            width INTEGER NOT NULL CHECK (width > 0),
            height INTEGER NOT NULL CHECK (height > 0),
            frame_count INTEGER NOT NULL DEFAULT 0 CHECK (frame_count >= 0),
            byte_count INTEGER NOT NULL DEFAULT 0 CHECK (byte_count >= 0),
            sha256 TEXT,
            state TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE frames (
            id TEXT NOT NULL PRIMARY KEY,
            captured_at TEXT NOT NULL,
            monotonic_ns INTEGER NOT NULL CHECK (monotonic_ns >= 0),
            capture_epoch_id TEXT NOT NULL,
            target_window_id INTEGER NOT NULL,
            chunk_id TEXT NOT NULL REFERENCES media_chunks(id) ON DELETE CASCADE,
            pts_ms INTEGER NOT NULL CHECK (pts_ms >= 0),
            thumbnail_path TEXT,
            bundle_id TEXT,
            app_name TEXT,
            window_title TEXT,
            window_x REAL,
            window_y REAL,
            window_w REAL,
            window_h REAL,
            browser_family TEXT,
            url_scheme TEXT,
            url_host TEXT,
            url_path TEXT,
            capture_reason TEXT NOT NULL,
            is_transition INTEGER NOT NULL CHECK (is_transition IN (0, 1)),
            text_state TEXT NOT NULL,
            visual_state TEXT NOT NULL,
            schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
            approved_text TEXT NOT NULL DEFAULT '',
            UNIQUE (chunk_id, pts_ms)
        )
        """,
        """
        CREATE TABLE text_spans (
            id TEXT NOT NULL PRIMARY KEY,
            frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            text TEXT NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL,
            confidence REAL NOT NULL,
            language_code TEXT,
            sensitivity TEXT NOT NULL
        )
        """,
        """
        CREATE VIRTUAL TABLE frame_fts USING fts5(
            approved_text,
            window_title,
            app_name,
            url_host,
            url_path,
            content='frames',
            content_rowid='rowid',
            tokenize='unicode61'
        )
        """,
        """
        CREATE TABLE artifacts (
            id TEXT NOT NULL PRIMARY KEY,
            frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            producer_name TEXT NOT NULL,
            producer_version TEXT NOT NULL,
            model_hash TEXT,
            locator_kind TEXT NOT NULL,
            locator_value TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            state TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE vector_offsets (
            frame_id TEXT NOT NULL PRIMARY KEY REFERENCES frames(id) ON DELETE CASCADE,
            model_hash TEXT NOT NULL,
            byte_offset INTEGER NOT NULL CHECK (byte_offset >= 0),
            dimension INTEGER NOT NULL CHECK (dimension > 0),
            norm REAL NOT NULL CHECK (norm >= 0),
            state TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE activity_intervals (
            id TEXT NOT NULL PRIMARY KEY,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            bundle_id TEXT,
            app_name TEXT,
            state TEXT NOT NULL,
            gap_reason TEXT
        )
        """,
        """
        CREATE TABLE processing_jobs (
            id TEXT NOT NULL PRIMARY KEY,
            parent_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            priority INTEGER NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 3),
            next_attempt_at TEXT,
            producer_version TEXT NOT NULL,
            error_code TEXT,
            lease_expires_at TEXT
        )
        """,
        """
        CREATE TABLE policy_decisions (
            id TEXT NOT NULL PRIMARY KEY,
            decided_at TEXT NOT NULL,
            bundle_id TEXT,
            host TEXT,
            private_context INTEGER NOT NULL CHECK (private_context IN (0, 1)),
            result TEXT NOT NULL,
            matched_rule_id TEXT
        )
        """,
        """
        CREATE TABLE access_policies (
            id TEXT NOT NULL PRIMARY KEY,
            encoded_policy TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            created_by_user INTEGER NOT NULL CHECK (created_by_user IN (0, 1))
        )
        """,
        """
        CREATE TABLE deletion_tombstones (
            id TEXT NOT NULL PRIMARY KEY,
            encoded_tombstone TEXT NOT NULL,
            state TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE audit_events (
            id TEXT NOT NULL PRIMARY KEY,
            occurred_at TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            policy_id TEXT REFERENCES access_policies(id) ON DELETE SET NULL,
            result_count INTEGER NOT NULL CHECK (result_count >= 0),
            query_hash TEXT
        )
        """,
        "CREATE INDEX media_chunks_started_at_idx ON media_chunks(started_at, id)",
        "CREATE INDEX frames_captured_at_idx ON frames(captured_at, id)",
        "CREATE INDEX frames_chunk_pts_idx ON frames(chunk_id, pts_ms)",
        "CREATE INDEX frames_bundle_captured_idx ON frames(bundle_id, captured_at, id)",
        "CREATE INDEX text_spans_frame_idx ON text_spans(frame_id)",
        "CREATE INDEX artifacts_frame_idx ON artifacts(frame_id)",
        "CREATE INDEX artifacts_state_kind_idx ON artifacts(state, kind)",
        "CREATE INDEX activity_intervals_started_idx ON activity_intervals(started_at, id)",
        "CREATE INDEX processing_jobs_schedule_idx ON processing_jobs(state, priority DESC, next_attempt_at, id)",
        "CREATE INDEX policy_decisions_decided_idx ON policy_decisions(decided_at, id)",
        "CREATE INDEX access_policies_expires_idx ON access_policies(expires_at, id)",
        "CREATE INDEX audit_events_occurred_idx ON audit_events(occurred_at, id)",
    ]
}
