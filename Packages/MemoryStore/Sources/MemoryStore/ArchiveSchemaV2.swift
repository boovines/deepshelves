import GRDB

enum ArchiveSchemaV2 {
    static let migrationIdentifier = "v2_heic_frame_locators"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            migrationIdentifier,
            foreignKeyChecks: .immediate
        ) { database in
            try database.execute(sql: "ALTER TABLE frames ADD COLUMN media_path TEXT")
            try database.execute(sql: "ALTER TABLE frames ADD COLUMN media_sha256 TEXT")
            try database.execute(
                sql:
                    "ALTER TABLE frames ADD COLUMN media_byte_count INTEGER CHECK (media_byte_count IS NULL OR media_byte_count > 0)"
            )
            try database.execute(
                sql:
                    "ALTER TABLE frames ADD COLUMN policy_generation INTEGER CHECK (policy_generation IS NULL OR policy_generation > 0)"
            )
            try database.execute(
                sql:
                    "CREATE UNIQUE INDEX frames_media_path_v2_idx ON frames(media_path) WHERE media_path IS NOT NULL"
            )
            try database.execute(
                sql: """
                    CREATE TRIGGER frames_v2_locator_insert
                    BEFORE INSERT ON frames
                    WHEN NEW.schema_version >= 2 AND (
                        NEW.media_path IS NULL
                        OR NEW.media_path NOT LIKE 'media/%/frames/' || lower(NEW.id) || '.heic'
                        OR instr(NEW.media_path, '..') > 0
                        OR instr(NEW.media_path, '//') > 0
                        OR instr(NEW.media_path, '.partial') > 0
                        OR NEW.media_sha256 IS NULL
                        OR length(NEW.media_sha256) <> 64
                        OR NEW.media_sha256 GLOB '*[^0-9a-f]*'
                        OR NEW.media_byte_count IS NULL
                        OR NEW.media_byte_count <= 0
                        OR NEW.policy_generation IS NULL
                        OR NEW.policy_generation <= 0
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'schema V2 frames require an exact canonical HEIC locator');
                    END
                    """
            )
            try database.execute(
                sql: """
                    CREATE TRIGGER frames_v2_locator_update
                    BEFORE UPDATE OF id, schema_version, media_path, media_sha256,
                                     media_byte_count, policy_generation ON frames
                    WHEN NEW.schema_version >= 2 AND (
                        NEW.media_path IS NULL
                        OR NEW.media_path NOT LIKE 'media/%/frames/' || lower(NEW.id) || '.heic'
                        OR instr(NEW.media_path, '..') > 0
                        OR instr(NEW.media_path, '//') > 0
                        OR instr(NEW.media_path, '.partial') > 0
                        OR NEW.media_sha256 IS NULL
                        OR length(NEW.media_sha256) <> 64
                        OR NEW.media_sha256 GLOB '*[^0-9a-f]*'
                        OR NEW.media_byte_count IS NULL
                        OR NEW.media_byte_count <= 0
                        OR NEW.policy_generation IS NULL
                        OR NEW.policy_generation <= 0
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'schema V2 frames require an exact canonical HEIC locator');
                    END
                    """
            )
            try database.execute(
                sql:
                    "UPDATE archive_meta SET value = '2' WHERE key IN ('schema_version', 'contract_version')"
            )
        }
    }
}
