import GRDB

enum ArchiveSchemaV3 {
    static let migrationIdentifier = "v3_merged_text_fts"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            migrationIdentifier,
            foreignKeyChecks: .immediate
        ) { database in
            try database.execute(sql: "ALTER TABLE text_spans RENAME TO text_spans_v2")
            try database.execute(
                sql: """
                    CREATE TABLE text_spans (
                        id TEXT NOT NULL PRIMARY KEY,
                        frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
                        source TEXT NOT NULL,
                        text TEXT NOT NULL,
                        x REAL,
                        y REAL,
                        w REAL,
                        h REAL,
                        confidence REAL,
                        language_code TEXT,
                        sensitivity TEXT NOT NULL
                    )
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO text_spans(
                        id, frame_id, source, text, x, y, w, h,
                        confidence, language_code, sensitivity
                    )
                    SELECT id, frame_id, source, text, x, y, w, h,
                           confidence, language_code, sensitivity
                    FROM text_spans_v2
                    """
            )
            try database.execute(sql: "DROP TABLE text_spans_v2")
            try database.execute(
                sql: "CREATE INDEX text_spans_frame_idx ON text_spans(frame_id)"
            )
            try database.execute(
                sql: """
                    CREATE TABLE merged_text_records (
                        frame_id TEXT NOT NULL PRIMARY KEY
                            REFERENCES frames(id) ON DELETE CASCADE,
                        approved_text TEXT NOT NULL,
                        transcript_text TEXT NOT NULL DEFAULT '',
                        window_title TEXT,
                        app_name TEXT,
                        url_host TEXT,
                        url_path TEXT,
                        producer_version TEXT NOT NULL,
                        state TEXT NOT NULL CHECK (state IN ('ready', 'suppressed'))
                    )
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO merged_text_records(
                        frame_id, approved_text, transcript_text, window_title,
                        app_name, url_host, url_path, producer_version, state
                    )
                    SELECT id, approved_text, '', window_title,
                           app_name, url_host, url_path, 'legacy-v2', 'ready'
                    FROM frames
                    WHERE text_state = 'ready'
                    """
            )
            try database.execute(sql: "DROP TABLE frame_fts")
            try database.execute(
                sql: """
                    CREATE VIRTUAL TABLE frame_fts USING fts5(
                        approved_text,
                        window_title,
                        app_name,
                        url_host,
                        url_path,
                        transcript_text,
                        content='merged_text_records',
                        content_rowid='rowid',
                        tokenize='unicode61'
                    )
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO frame_fts(
                        rowid, approved_text, window_title, app_name,
                        url_host, url_path, transcript_text
                    )
                    SELECT rowid, approved_text, window_title, app_name,
                           url_host, url_path, transcript_text
                    FROM merged_text_records
                    WHERE state = 'ready'
                    """
            )
            try database.execute(
                sql: "UPDATE archive_meta SET value = '3' WHERE key = 'schema_version'"
            )
        }
    }
}
