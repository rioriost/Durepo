import Foundation
import SQLite3

final class SQLiteMetadata {
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw CocoaError(.fileReadUnknown)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA busy_timeout=5000")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
            CREATE TABLE IF NOT EXISTS snapshots (
                id TEXT PRIMARY KEY,
                repository_id TEXT NOT NULL,
                repository_name TEXT NOT NULL,
                created_at REAL NOT NULL,
                reason TEXT NOT NULL,
                manifest_file TEXT NOT NULL UNIQUE,
                file_count INTEGER NOT NULL,
                logical_byte_count INTEGER NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS snapshots_repository_created ON snapshots(repository_id, created_at DESC)")
        if try !hasColumn("is_protected", in: "snapshots") {
            try execute("ALTER TABLE snapshots ADD COLUMN is_protected INTEGER NOT NULL DEFAULT 0")
        }
        if try !hasColumn("health_state", in: "snapshots") {
            try execute("ALTER TABLE snapshots ADD COLUMN health_state TEXT NOT NULL DEFAULT 'normal'")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS snapshot_entries (
                snapshot_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                content_hash TEXT,
                byte_count INTEGER NOT NULL,
                posix_mode INTEGER NOT NULL,
                modified_at REAL,
                symbolic_link_destination TEXT,
                hard_link_group TEXT,
                allocated_byte_count INTEGER,
                extended_attributes BLOB,
                acl_text TEXT,
                PRIMARY KEY(snapshot_id, relative_path)
            )
            """)
        if try !hasColumn("hard_link_group", in: "snapshot_entries") {
            try execute("ALTER TABLE snapshot_entries ADD COLUMN hard_link_group TEXT")
        }
        if try !hasColumn("allocated_byte_count", in: "snapshot_entries") {
            try execute("ALTER TABLE snapshot_entries ADD COLUMN allocated_byte_count INTEGER")
        }
        if try !hasColumn("extended_attributes", in: "snapshot_entries") {
            try execute("ALTER TABLE snapshot_entries ADD COLUMN extended_attributes BLOB")
        }
        if try !hasColumn("acl_text", in: "snapshot_entries") {
            try execute("ALTER TABLE snapshot_entries ADD COLUMN acl_text TEXT")
        }
        try execute("CREATE INDEX IF NOT EXISTS snapshot_entries_path ON snapshot_entries(relative_path)")
        try execute("""
            CREATE TABLE IF NOT EXISTS monitor_state (
                repository_id TEXT PRIMARY KEY,
                volume_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                last_seen_event_id INTEGER NOT NULL DEFAULT 0,
                last_committed_event_id INTEGER NOT NULL DEFAULT 0,
                pending INTEGER NOT NULL DEFAULT 1,
                needs_full_scan INTEGER NOT NULL DEFAULT 1,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS event_batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                repository_id TEXT NOT NULL,
                event_id INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                needs_full_scan INTEGER NOT NULL DEFAULT 0,
                received_at REAL NOT NULL
            )
            """)
        if try !hasColumn("needs_full_scan", in: "event_batches") {
            try execute("ALTER TABLE event_batches ADD COLUMN needs_full_scan INTEGER NOT NULL DEFAULT 0")
        }
        try execute("CREATE INDEX IF NOT EXISTS event_batches_repository_event ON event_batches(repository_id, event_id)")
        try execute("""
            CREATE TABLE IF NOT EXISTS event_paths (
                repository_id TEXT NOT NULL,
                event_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                PRIMARY KEY(repository_id, event_id, relative_path)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS event_paths_repository_event ON event_paths(repository_id, event_id)")
        try execute("""
            CREATE TABLE IF NOT EXISTS repository_indexes (
                repository_id TEXT PRIMARY KEY,
                snapshot_id TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS current_entries (
                repository_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                content_hash TEXT,
                byte_count INTEGER NOT NULL,
                posix_mode INTEGER NOT NULL,
                modified_at REAL,
                symbolic_link_destination TEXT,
                hard_link_group TEXT,
                allocated_byte_count INTEGER,
                extended_attributes BLOB,
                acl_text TEXT,
                device INTEGER,
                inode INTEGER,
                file_size INTEGER,
                mtime_seconds INTEGER,
                mtime_nanoseconds INTEGER,
                ctime_seconds INTEGER,
                ctime_nanoseconds INTEGER,
                PRIMARY KEY(repository_id, relative_path)
            )
            """)
        if try !hasColumn("hard_link_group", in: "current_entries") {
            try execute("ALTER TABLE current_entries ADD COLUMN hard_link_group TEXT")
        }
        if try !hasColumn("allocated_byte_count", in: "current_entries") {
            try execute("ALTER TABLE current_entries ADD COLUMN allocated_byte_count INTEGER")
        }
        if try !hasColumn("extended_attributes", in: "current_entries") {
            try execute("ALTER TABLE current_entries ADD COLUMN extended_attributes BLOB")
        }
        if try !hasColumn("acl_text", in: "current_entries") {
            try execute("ALTER TABLE current_entries ADD COLUMN acl_text TEXT")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS agent_errors (
                repository_id TEXT PRIMARY KEY,
                error_id TEXT NOT NULL,
                message TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS protection_alerts (
                id TEXT PRIMARY KEY,
                repository_id TEXT NOT NULL,
                snapshot_id TEXT,
                protected_snapshot_id TEXT,
                kind TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at REAL NOT NULL,
                acknowledged_at REAL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS protection_alerts_repository_created ON protection_alerts(repository_id, created_at DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS restore_suppressions (
                repository_id TEXT PRIMARY KEY,
                created_at REAL NOT NULL
            )
            """)
        try execute("PRAGMA user_version=6")
    }

    deinit { sqlite3_close(database) }

    func index(_ manifest: SnapshotManifest, manifestFile: String) throws {
        try transaction {
            try upsertSnapshot(manifest, manifestFile: manifestFile, healthState: .normal)
            try replaceSnapshotEntries(snapshotID: manifest.id, entries: manifest.entries)
        }
    }

    func indexEntries(_ manifest: SnapshotManifest) throws {
        try transaction {
            try replaceSnapshotEntries(snapshotID: manifest.id, entries: manifest.entries)
        }
    }

    func commitSnapshot(
        _ manifest: SnapshotManifest,
        manifestFile: String,
        currentEntries: [IndexedSnapshotEntry],
        anomaly: RepositoryAnomaly?
    ) throws {
        return try transaction {
            let previousSnapshotID = try indexedSnapshotID(repositoryID: manifest.repositoryID)
            try upsertSnapshot(
                manifest,
                manifestFile: manifestFile,
                healthState: anomaly == nil ? .normal : .anomalous
            )
            try replaceSnapshotEntries(snapshotID: manifest.id, entries: manifest.entries)
            if let anomaly, try !hasActiveProtectionAlert(repositoryID: manifest.repositoryID) {
                if let previousSnapshotID {
                    try setSnapshotProtected(id: previousSnapshotID, isProtected: true)
                }
                try insertProtectionAlert(
                    repositoryID: manifest.repositoryID,
                    snapshotID: manifest.id,
                    protectedSnapshotID: previousSnapshotID,
                    anomaly: anomaly
                )
            }
            try withStatement("DELETE FROM current_entries WHERE repository_id = ?") { statement in
                bind(manifest.repositoryID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("""
                INSERT INTO current_entries(
                    repository_id, relative_path, kind, content_hash, byte_count, posix_mode,
                    modified_at, symbolic_link_destination, hard_link_group, allocated_byte_count,
                    extended_attributes, acl_text, device, inode, file_size, mtime_seconds,
                    mtime_nanoseconds, ctime_seconds, ctime_nanoseconds
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                    for indexed in currentEntries {
                        let entry = indexed.entry
                        bind(manifest.repositoryID.uuidString, at: 1, in: statement)
                        bind(entry.relativePath, at: 2, in: statement)
                        bind(entry.kind.rawValue, at: 3, in: statement)
                        bind(entry.contentHash, at: 4, in: statement)
                        sqlite3_bind_int64(statement, 5, entry.byteCount)
                        sqlite3_bind_int64(statement, 6, Int64(entry.posixMode))
                        bind(entry.modifiedAt?.timeIntervalSince1970, at: 7, in: statement)
                        bind(entry.symbolicLinkDestination, at: 8, in: statement)
                        bind(entry.hardLinkGroup, at: 9, in: statement)
                        if let allocatedByteCount = entry.allocatedByteCount {
                            sqlite3_bind_int64(statement, 10, allocatedByteCount)
                        } else {
                            sqlite3_bind_null(statement, 10)
                        }
                        let attributes = try entry.extendedAttributes.map(JSONEncoder.durepo.encode)
                        bind(attributes, at: 11, in: statement)
                        bind(entry.aclText, at: 12, in: statement)
                        if let fingerprint = indexed.fingerprint {
                            sqlite3_bind_int64(statement, 13, Int64(bitPattern: fingerprint.device))
                            sqlite3_bind_int64(statement, 14, Int64(bitPattern: fingerprint.inode))
                            sqlite3_bind_int64(statement, 15, fingerprint.size)
                            sqlite3_bind_int64(statement, 16, fingerprint.modificationSeconds)
                            sqlite3_bind_int64(statement, 17, fingerprint.modificationNanoseconds)
                            sqlite3_bind_int64(statement, 18, fingerprint.statusSeconds)
                            sqlite3_bind_int64(statement, 19, fingerprint.statusNanoseconds)
                        } else {
                            for index in 13...19 { sqlite3_bind_null(statement, Int32(index)) }
                        }
                        try stepDone(statement)
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                    }
                }
            try withStatement("""
                INSERT INTO repository_indexes(repository_id, snapshot_id) VALUES(?, ?)
                ON CONFLICT(repository_id) DO UPDATE SET snapshot_id=excluded.snapshot_id
                """) { statement in
                    bind(manifest.repositoryID.uuidString, at: 1, in: statement)
                    bind(manifest.id.uuidString, at: 2, in: statement)
                    try stepDone(statement)
                }
        }
    }

    func currentEntries(repositoryID: UUID) throws -> [String: IndexedSnapshotEntry]? {
        let hasIndex = try withStatement("SELECT 1 FROM repository_indexes WHERE repository_id = ?") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
        guard hasIndex else { return nil }

        return try withStatement("""
            SELECT relative_path, kind, content_hash, byte_count, posix_mode, modified_at,
                symbolic_link_destination, hard_link_group, allocated_byte_count,
                extended_attributes, acl_text, device, inode, file_size, mtime_seconds,
                mtime_nanoseconds, ctime_seconds, ctime_nanoseconds
            FROM current_entries WHERE repository_id = ?
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                var result: [String: IndexedSnapshotEntry] = [:]
                while sqlite3_step(statement) == SQLITE_ROW {
                    let relativePath = text(statement, 0)
                    guard let kind = SnapshotEntryKind(rawValue: text(statement, 1)) else { continue }
                    let entry = SnapshotEntry(
                        relativePath: relativePath,
                        kind: kind,
                        contentHash: optionalText(statement, 2),
                        byteCount: sqlite3_column_int64(statement, 3),
                        posixMode: UInt32(clamping: sqlite3_column_int64(statement, 4)),
                        modifiedAt: optionalDouble(statement, 5).map(Date.init(timeIntervalSince1970:)),
                        symbolicLinkDestination: optionalText(statement, 6),
                        hardLinkGroup: optionalText(statement, 7),
                        allocatedByteCount: optionalInt64(statement, 8),
                        extendedAttributes: try optionalData(statement, 9).map {
                            try JSONDecoder.durepo.decode([SnapshotExtendedAttribute].self, from: $0)
                        },
                        aclText: optionalText(statement, 10)
                    )
                    let fingerprint: FileFingerprint?
                    if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                        fingerprint = nil
                    } else {
                        fingerprint = FileFingerprint(
                            device: UInt64(bitPattern: sqlite3_column_int64(statement, 11)),
                            inode: UInt64(bitPattern: sqlite3_column_int64(statement, 12)),
                            size: sqlite3_column_int64(statement, 13),
                            modificationSeconds: sqlite3_column_int64(statement, 14),
                            modificationNanoseconds: sqlite3_column_int64(statement, 15),
                            statusSeconds: sqlite3_column_int64(statement, 16),
                            statusNanoseconds: sqlite3_column_int64(statement, 17)
                        )
                    }
                    result[relativePath] = IndexedSnapshotEntry(entry: entry, fingerprint: fingerprint)
                }
                return result
            }
    }

    func invalidateCurrentIndex(repositoryID: UUID) throws {
        try transaction {
            try withStatement("DELETE FROM current_entries WHERE repository_id = ?") { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM repository_indexes WHERE repository_id = ?") { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    private func upsertSnapshot(
        _ manifest: SnapshotManifest,
        manifestFile: String,
        healthState: SnapshotHealthState
    ) throws {
        try withStatement("""
            INSERT INTO snapshots(id, repository_id, repository_name, created_at, reason, manifest_file,
                file_count, logical_byte_count, health_state)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                repository_id=excluded.repository_id,
                repository_name=excluded.repository_name,
                created_at=excluded.created_at,
                reason=excluded.reason,
                manifest_file=excluded.manifest_file,
                file_count=excluded.file_count,
                logical_byte_count=excluded.logical_byte_count,
                health_state=excluded.health_state
            """) { statement in
                bind(manifest.id.uuidString, at: 1, in: statement)
                bind(manifest.repositoryID.uuidString, at: 2, in: statement)
                bind(manifest.repositoryName, at: 3, in: statement)
                sqlite3_bind_double(statement, 4, manifest.createdAt.timeIntervalSince1970)
                bind(manifest.reason.rawValue, at: 5, in: statement)
                bind(manifestFile, at: 6, in: statement)
                sqlite3_bind_int64(statement, 7, Int64(manifest.fileCount))
                sqlite3_bind_int64(statement, 8, manifest.logicalByteCount)
                bind(healthState.rawValue, at: 9, in: statement)
                try stepDone(statement)
        }
    }

    private func replaceSnapshotEntries(snapshotID: UUID, entries: [SnapshotEntry]) throws {
        try withStatement("DELETE FROM snapshot_entries WHERE snapshot_id = ?") { statement in
            bind(snapshotID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
        try withStatement("""
            INSERT INTO snapshot_entries(
                snapshot_id, relative_path, kind, content_hash, byte_count, posix_mode,
                modified_at, symbolic_link_destination, hard_link_group, allocated_byte_count,
                extended_attributes, acl_text
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
                for entry in entries {
                    bind(snapshotID.uuidString, at: 1, in: statement)
                    bind(entry.relativePath, at: 2, in: statement)
                    bind(entry.kind.rawValue, at: 3, in: statement)
                    bind(entry.contentHash, at: 4, in: statement)
                    sqlite3_bind_int64(statement, 5, entry.byteCount)
                    sqlite3_bind_int64(statement, 6, Int64(entry.posixMode))
                    bind(entry.modifiedAt?.timeIntervalSince1970, at: 7, in: statement)
                    bind(entry.symbolicLinkDestination, at: 8, in: statement)
                    bind(entry.hardLinkGroup, at: 9, in: statement)
                    if let allocatedByteCount = entry.allocatedByteCount {
                        sqlite3_bind_int64(statement, 10, allocatedByteCount)
                    } else {
                        sqlite3_bind_null(statement, 10)
                    }
                    bind(try entry.extendedAttributes.map(JSONEncoder.durepo.encode), at: 11, in: statement)
                    bind(entry.aclText, at: 12, in: statement)
                    try stepDone(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
    }

    private func previousSnapshotID(before snapshotID: UUID) throws -> UUID? {
        try withStatement("""
            SELECT older.id
            FROM snapshots target
            JOIN snapshots older ON older.repository_id = target.repository_id
                AND (older.created_at < target.created_at
                    OR (older.created_at = target.created_at AND older.rowid < target.rowid))
            WHERE target.id = ?
            ORDER BY older.created_at DESC, older.rowid DESC LIMIT 1
            """) { statement in
                bind(snapshotID.uuidString, at: 1, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return UUID(uuidString: text(statement, 0))
            }
    }

    func containsSnapshot(id: UUID) throws -> Bool {
        try withStatement("SELECT 1 FROM snapshots WHERE id = ? LIMIT 1") { statement in
            bind(id.uuidString, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func containsSnapshotEntries(id: UUID) throws -> Bool {
        try withStatement("SELECT 1 FROM snapshot_entries WHERE snapshot_id = ? LIMIT 1") { statement in
            bind(id.uuidString, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func snapshotDiff(snapshotID: UUID, offset: Int, limit: Int) throws -> SnapshotDiffPage {
        let boundedOffset = max(0, offset)
        let boundedLimit = max(1, min(limit, 1_000))
        guard let previousSnapshotID = try previousSnapshotID(before: snapshotID) else {
            let entries = try withStatement("""
                SELECT relative_path, kind, byte_count
                FROM snapshot_entries WHERE snapshot_id = ?
                ORDER BY relative_path LIMIT ? OFFSET ?
                """) { statement in
                    bind(snapshotID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, Int64(boundedLimit + 1))
                    sqlite3_bind_int64(statement, 3, Int64(boundedOffset))
                    var result: [SnapshotDiffEntry] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let entryKind = SnapshotEntryKind(rawValue: text(statement, 1)) else { continue }
                        result.append(SnapshotDiffEntry(
                            relativePath: text(statement, 0),
                            kind: .added,
                            entryKind: entryKind,
                            byteCount: sqlite3_column_int64(statement, 2)
                        ))
                    }
                    return result
                }
            return SnapshotDiffPage(
                entries: Array(entries.prefix(boundedLimit)),
                offset: boundedOffset,
                hasMore: entries.count > boundedLimit
            )
        }

        let entries = try withStatement("""
            WITH paths(relative_path) AS (
                SELECT relative_path FROM snapshot_entries WHERE snapshot_id = ?
                UNION
                SELECT relative_path FROM snapshot_entries WHERE snapshot_id = ?
            )
            SELECT paths.relative_path,
                CASE
                    WHEN older.relative_path IS NULL THEN 'added'
                    WHEN newer.relative_path IS NULL THEN 'removed'
                    ELSE 'modified'
                END,
                COALESCE(newer.kind, older.kind),
                COALESCE(newer.byte_count, older.byte_count)
            FROM paths
            LEFT JOIN snapshot_entries older
                ON older.snapshot_id = ? AND older.relative_path = paths.relative_path
            LEFT JOIN snapshot_entries newer
                ON newer.snapshot_id = ? AND newer.relative_path = paths.relative_path
            WHERE older.relative_path IS NULL OR newer.relative_path IS NULL
                OR NOT (older.kind IS newer.kind)
                OR NOT (older.content_hash IS newer.content_hash)
                OR older.byte_count != newer.byte_count
                OR older.posix_mode != newer.posix_mode
                OR NOT (older.symbolic_link_destination IS newer.symbolic_link_destination)
                OR NOT (older.hard_link_group IS newer.hard_link_group)
                OR NOT (older.allocated_byte_count IS newer.allocated_byte_count)
                OR NOT (older.extended_attributes IS newer.extended_attributes)
                OR NOT (older.acl_text IS newer.acl_text)
            ORDER BY paths.relative_path LIMIT ? OFFSET ?
            """) { statement in
                bind(previousSnapshotID.uuidString, at: 1, in: statement)
                bind(snapshotID.uuidString, at: 2, in: statement)
                bind(previousSnapshotID.uuidString, at: 3, in: statement)
                bind(snapshotID.uuidString, at: 4, in: statement)
                sqlite3_bind_int64(statement, 5, Int64(boundedLimit + 1))
                sqlite3_bind_int64(statement, 6, Int64(boundedOffset))
                var result: [SnapshotDiffEntry] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let kind = SnapshotDiffKind(rawValue: text(statement, 1)),
                          let entryKind = SnapshotEntryKind(rawValue: text(statement, 2)) else { continue }
                    result.append(SnapshotDiffEntry(
                        relativePath: text(statement, 0),
                        kind: kind,
                        entryKind: entryKind,
                        byteCount: sqlite3_column_int64(statement, 3)
                    ))
                }
                return result
            }
        return SnapshotDiffPage(
            entries: Array(entries.prefix(boundedLimit)),
            offset: boundedOffset,
            hasMore: entries.count > boundedLimit
        )
    }

    func snapshotEntries(snapshotID: UUID, offset: Int, limit: Int) throws -> SnapshotDiffPage {
        let boundedOffset = max(0, offset)
        let boundedLimit = max(1, min(limit, 1_000))
        let entries = try withStatement("""
            SELECT relative_path, kind, byte_count
            FROM snapshot_entries WHERE snapshot_id = ?
            ORDER BY relative_path LIMIT ? OFFSET ?
            """) { statement in
                bind(snapshotID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, Int64(boundedLimit + 1))
                sqlite3_bind_int64(statement, 3, Int64(boundedOffset))
                var result: [SnapshotDiffEntry] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let entryKind = SnapshotEntryKind(rawValue: text(statement, 1)) else { continue }
                    result.append(SnapshotDiffEntry(
                        relativePath: text(statement, 0),
                        kind: .unchanged,
                        entryKind: entryKind,
                        byteCount: sqlite3_column_int64(statement, 2)
                    ))
                }
                return result
            }
        return SnapshotDiffPage(
            entries: Array(entries.prefix(boundedLimit)),
            offset: boundedOffset,
            hasMore: entries.count > boundedLimit
        )
    }

    func summaries(repositoryID: UUID?, limit: Int) throws -> [SnapshotSummary] {
        let filtered = repositoryID != nil
        let sql = """
            SELECT id, repository_id, repository_name, created_at, reason, file_count, logical_byte_count,
                is_protected, health_state
            FROM snapshots
            \(filtered ? "WHERE repository_id = ?" : "")
            ORDER BY created_at DESC LIMIT ?
            """
        return try withStatement(sql) { statement in
            var bindIndex: Int32 = 1
            if let repositoryID {
                bind(repositoryID.uuidString, at: bindIndex, in: statement)
                bindIndex += 1
            }
            sqlite3_bind_int64(statement, bindIndex, Int64(limit))
            var result: [SnapshotSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)),
                      let repositoryID = UUID(uuidString: text(statement, 1)),
                      let reason = SnapshotReason(rawValue: text(statement, 4)),
                      let healthState = SnapshotHealthState(rawValue: text(statement, 8)) else { continue }
                result.append(SnapshotSummary(
                    id: id,
                    repositoryID: repositoryID,
                    repositoryName: text(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    reason: reason,
                    fileCount: Int(sqlite3_column_int64(statement, 5)),
                    logicalByteCount: sqlite3_column_int64(statement, 6),
                    isProtected: sqlite3_column_int(statement, 7) != 0,
                    healthState: healthState
                ))
            }
            return result
        }
    }

    func protectionAlerts(includeAcknowledged: Bool = false) throws -> [ProtectionAlert] {
        let sql = """
            SELECT id, repository_id, snapshot_id, protected_snapshot_id, kind, message,
                created_at, acknowledged_at
            FROM protection_alerts
            \(includeAcknowledged ? "" : "WHERE acknowledged_at IS NULL")
            ORDER BY created_at DESC
            """
        return try withStatement(sql) { statement in
            var alerts: [ProtectionAlert] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)),
                      let repositoryID = UUID(uuidString: text(statement, 1)),
                      let kind = RepositoryAnomalyKind(rawValue: text(statement, 4)) else { continue }
                alerts.append(ProtectionAlert(
                    id: id,
                    repositoryID: repositoryID,
                    snapshotID: optionalText(statement, 2).flatMap(UUID.init(uuidString:)),
                    protectedSnapshotID: optionalText(statement, 3).flatMap(UUID.init(uuidString:)),
                    kind: kind,
                    message: text(statement, 5),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    acknowledgedAt: optionalDouble(statement, 7).map(Date.init(timeIntervalSince1970:))
                ))
            }
            return alerts
        }
    }

    func acknowledgeProtectionAlert(id: UUID) throws {
        try withStatement("UPDATE protection_alerts SET acknowledged_at = ? WHERE id = ?") { statement in
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bind(id.uuidString, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    func setSnapshotProtected(id: UUID, isProtected: Bool) throws {
        try withStatement("UPDATE snapshots SET is_protected = ? WHERE id = ?") { statement in
            sqlite3_bind_int(statement, 1, isProtected ? 1 : 0)
            bind(id.uuidString, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    func markRestoreCompleted(repositoryID: UUID) throws {
        try withStatement("""
            INSERT INTO restore_suppressions(repository_id, created_at) VALUES(?, ?)
            ON CONFLICT(repository_id) DO UPDATE SET created_at=excluded.created_at
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                try stepDone(statement)
            }
    }

    func hasRestoreSuppression(repositoryID: UUID) throws -> Bool {
        try withStatement("SELECT 1 FROM restore_suppressions WHERE repository_id = ? LIMIT 1") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func clearRestoreSuppression(repositoryID: UUID) throws {
        try withStatement("DELETE FROM restore_suppressions WHERE repository_id = ?") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    @discardableResult
    func recordProtectionAlert(repositoryID: UUID, anomaly: RepositoryAnomaly) throws -> ProtectionAlert {
        if let existing = try protectionAlerts().first(where: {
            $0.repositoryID == repositoryID && $0.kind == anomaly.kind
        }) {
            return existing
        }
        return try transaction {
            let protectedSnapshotID = try indexedSnapshotID(repositoryID: repositoryID)
            if let protectedSnapshotID {
                try setSnapshotProtected(id: protectedSnapshotID, isProtected: true)
            }
            return try insertProtectionAlert(
                repositoryID: repositoryID,
                snapshotID: nil,
                protectedSnapshotID: protectedSnapshotID,
                anomaly: anomaly
            )
        }
    }

    private func indexedSnapshotID(repositoryID: UUID) throws -> UUID? {
        try withStatement("SELECT snapshot_id FROM repository_indexes WHERE repository_id = ?") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UUID(uuidString: text(statement, 0))
        }
    }

    private func hasActiveProtectionAlert(repositoryID: UUID) throws -> Bool {
        try withStatement("""
            SELECT 1 FROM protection_alerts
            WHERE repository_id = ? AND acknowledged_at IS NULL LIMIT 1
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                return sqlite3_step(statement) == SQLITE_ROW
            }
    }

    func hasAnyActiveProtectionAlert() throws -> Bool {
        try withStatement("SELECT 1 FROM protection_alerts WHERE acknowledged_at IS NULL LIMIT 1") { statement in
            sqlite3_step(statement) == SQLITE_ROW
        }
    }

    @discardableResult
    private func insertProtectionAlert(
        repositoryID: UUID,
        snapshotID: UUID?,
        protectedSnapshotID: UUID?,
        anomaly: RepositoryAnomaly
    ) throws -> ProtectionAlert {
        let alert = ProtectionAlert(
            id: UUID(),
            repositoryID: repositoryID,
            snapshotID: snapshotID,
            protectedSnapshotID: protectedSnapshotID,
            kind: anomaly.kind,
            message: anomaly.message,
            createdAt: .now,
            acknowledgedAt: nil
        )
        try withStatement("""
            INSERT INTO protection_alerts(id, repository_id, snapshot_id, protected_snapshot_id,
                kind, message, created_at, acknowledged_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, NULL)
            """) { statement in
                bind(alert.id.uuidString, at: 1, in: statement)
                bind(alert.repositoryID.uuidString, at: 2, in: statement)
                bind(alert.snapshotID?.uuidString, at: 3, in: statement)
                bind(alert.protectedSnapshotID?.uuidString, at: 4, in: statement)
                bind(alert.kind.rawValue, at: 5, in: statement)
                bind(alert.message, at: 6, in: statement)
                sqlite3_bind_double(statement, 7, alert.createdAt.timeIntervalSince1970)
                try stepDone(statement)
            }
        return alert
    }

    func manifestFile(id: UUID) throws -> String? {
        try withStatement("SELECT manifest_file FROM snapshots WHERE id = ?") { statement in
            bind(id.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(statement, 0)
        }
    }

    func manifestFiles(repositoryID: UUID) throws -> [String] {
        try withStatement("""
            SELECT manifest_file FROM snapshots
            WHERE repository_id = ? ORDER BY created_at DESC
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                var result: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
                return result
            }
    }

    func deleteRepositoryData(repositoryID: UUID) throws {
        try transaction {
            try withStatement("""
                DELETE FROM snapshot_entries WHERE snapshot_id IN (
                    SELECT id FROM snapshots WHERE repository_id = ?
                )
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    try stepDone(statement)
                }
            for table in [
                "snapshots", "current_entries", "repository_indexes", "event_paths",
                "event_batches", "monitor_state", "agent_errors", "protection_alerts",
                "restore_suppressions",
            ] {
                try withStatement("DELETE FROM \(table) WHERE repository_id = ?") { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    try stepDone(statement)
                }
            }
        }
    }

    func repositoryIDs() throws -> [UUID] {
        try withStatement("SELECT DISTINCT repository_id FROM snapshots") { statement in
            var result: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = UUID(uuidString: text(statement, 0)) { result.append(id) }
            }
            return result
        }
    }

    func integrityMessages() throws -> [String] {
        try withStatement("PRAGMA integrity_check") { statement in
            var messages: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { messages.append(text(statement, 0)) }
            return messages
        }
    }

    func pruneOldestCapacityCandidate() throws -> String? {
        try transaction {
            guard try !hasAnyActiveProtectionAlert() else { return nil }
            let candidate = try withStatement("""
                SELECT id, manifest_file FROM snapshots
                WHERE is_protected = 0
                    AND id NOT IN (SELECT snapshot_id FROM repository_indexes)
                ORDER BY created_at ASC LIMIT 1
                """) { statement -> (id: String, file: String)? in
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    return (text(statement, 0), text(statement, 1))
                }
            guard let candidate else { return nil }
            try withStatement("DELETE FROM snapshot_entries WHERE snapshot_id = ?") { statement in
                bind(candidate.id, at: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM snapshots WHERE id = ?") { statement in
                bind(candidate.id, at: 1, in: statement)
                try stepDone(statement)
            }
            return candidate.file
        }
    }

    func prune(repositoryID: UUID, keeping count: Int) throws -> [String] {
        return try transaction {
            let hasActiveAlert = try withStatement("""
                SELECT 1 FROM protection_alerts
                WHERE repository_id = ? AND acknowledged_at IS NULL LIMIT 1
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    return sqlite3_step(statement) == SQLITE_ROW
                }
            if hasActiveAlert { return [] }
            let files = try withStatement("""
                SELECT manifest_file FROM snapshots WHERE repository_id = ? AND is_protected = 0
                ORDER BY created_at DESC LIMIT -1 OFFSET ?
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, Int64(count))
                    var result: [String] = []
                    while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
                    return result
                }
            try withStatement("""
                DELETE FROM snapshot_entries WHERE snapshot_id IN (
                    SELECT id FROM snapshots WHERE repository_id = ? AND is_protected = 0
                    ORDER BY created_at DESC LIMIT -1 OFFSET ?
                )
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, Int64(count))
                    try stepDone(statement)
                }
            try withStatement("""
                DELETE FROM snapshots WHERE id IN (
                    SELECT id FROM snapshots WHERE repository_id = ? AND is_protected = 0
                    ORDER BY created_at DESC LIMIT -1 OFFSET ?
                )
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, Int64(count))
                    try stepDone(statement)
                }
            return files
        }
    }

    func prepareMonitor(repositoryID: UUID, volumeID: String, rootID: String) throws -> RepositoryMonitorState {
        let existing = try monitorState(repositoryID: repositoryID)
        let previousIdentity = try monitorIdentity(repositoryID: repositoryID)
        if let identity = previousIdentity,
           identity.volumeID == volumeID, identity.rootID == rootID {
            return existing ?? RepositoryMonitorState(lastSeenEventID: 0, lastCommittedEventID: 0, hasPendingEvents: true, needsFullScan: true)
        }
        try transaction {
            var tables = ["event_paths", "event_batches"]
            if previousIdentity != nil { tables += ["current_entries", "repository_indexes"] }
            for table in tables {
                try withStatement("DELETE FROM \(table) WHERE repository_id = ?") { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    try stepDone(statement)
                }
            }
            try withStatement("""
                INSERT INTO monitor_state(repository_id, volume_id, root_id, last_seen_event_id, last_committed_event_id, pending, needs_full_scan, updated_at)
                VALUES(?, ?, ?, 0, 0, 1, 1, ?)
                ON CONFLICT(repository_id) DO UPDATE SET volume_id=excluded.volume_id, root_id=excluded.root_id,
                    last_seen_event_id=0, last_committed_event_id=0, pending=1, needs_full_scan=1, updated_at=excluded.updated_at
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    bind(volumeID, at: 2, in: statement)
                    bind(rootID, at: 3, in: statement)
                    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                    try stepDone(statement)
                }
            }
        return RepositoryMonitorState(lastSeenEventID: 0, lastCommittedEventID: 0, hasPendingEvents: true, needsFullScan: true)
    }

    func recordEvent(
        repositoryID: UUID,
        eventID: UInt64,
        flags: UInt64,
        needsFullScan: Bool,
        changedPaths: [String]
    ) throws {
        let event = Int64(clamping: eventID)
        try transaction {
            try withStatement("INSERT INTO event_batches(repository_id, event_id, flags, needs_full_scan, received_at) VALUES(?, ?, ?, ?, ?)") { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, event)
                sqlite3_bind_int64(statement, 3, Int64(bitPattern: flags))
                sqlite3_bind_int(statement, 4, needsFullScan ? 1 : 0)
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
                try stepDone(statement)
            }
            try withStatement("INSERT OR IGNORE INTO event_paths(repository_id, event_id, relative_path) VALUES(?, ?, ?)") { statement in
                for path in Set(changedPaths) {
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, event)
                    bind(path, at: 3, in: statement)
                    try stepDone(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
            try withStatement("""
                UPDATE monitor_state SET last_seen_event_id = MAX(last_seen_event_id, ?), pending = 1,
                    needs_full_scan = MAX(needs_full_scan, ?), updated_at = ? WHERE repository_id = ?
                """) { statement in
                    sqlite3_bind_int64(statement, 1, event)
                    sqlite3_bind_int(statement, 2, needsFullScan ? 1 : 0)
                    sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                    bind(repositoryID.uuidString, at: 4, in: statement)
                    try stepDone(statement)
                }
        }
    }

    func requireFullScan(repositoryID: UUID) throws {
        try withStatement("""
            UPDATE monitor_state SET pending = 1, needs_full_scan = 1, updated_at = ?
            WHERE repository_id = ?
            """) { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                bind(repositoryID.uuidString, at: 2, in: statement)
                try stepDone(statement)
            }
    }

    func pendingChangeSet(repositoryID: UUID, through eventID: UInt64) throws -> SnapshotChangeSet {
        let event = Int64(clamping: eventID)
        let committed = Int64(clamping: try monitorState(repositoryID: repositoryID)?.lastCommittedEventID ?? 0)
        let needsFullScan = try withStatement("""
            SELECT COALESCE(MAX(needs_full_scan), 0) FROM event_batches
            WHERE repository_id = ? AND event_id > ? AND event_id <= ?
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, committed)
                sqlite3_bind_int64(statement, 3, event)
                guard sqlite3_step(statement) == SQLITE_ROW else { return true }
                return sqlite3_column_int(statement, 0) != 0
            }
        let paths = try withStatement("""
            SELECT DISTINCT relative_path FROM event_paths
            WHERE repository_id = ? AND event_id > ? AND event_id <= ?
            ORDER BY relative_path
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, committed)
                sqlite3_bind_int64(statement, 3, event)
                var result: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
                return result
            }
        return SnapshotChangeSet(
            changedPaths: paths,
            needsFullScan: needsFullScan || paths.isEmpty || paths.contains("")
        )
    }

    func monitorState(repositoryID: UUID) throws -> RepositoryMonitorState? {
        try withStatement("""
            SELECT last_seen_event_id, last_committed_event_id, pending, needs_full_scan
            FROM monitor_state WHERE repository_id = ?
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return RepositoryMonitorState(
                    lastSeenEventID: UInt64(max(0, sqlite3_column_int64(statement, 0))),
                    lastCommittedEventID: UInt64(max(0, sqlite3_column_int64(statement, 1))),
                    hasPendingEvents: sqlite3_column_int(statement, 2) != 0,
                    needsFullScan: sqlite3_column_int(statement, 3) != 0
                )
            }
    }

    func commitEvents(repositoryID: UUID, through eventID: UInt64) throws -> RepositoryMonitorState {
        let event = Int64(clamping: eventID)
        return try transaction {
            try withStatement("DELETE FROM event_paths WHERE repository_id = ? AND event_id <= ?") { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, event)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM event_batches WHERE repository_id = ? AND event_id <= ?") { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, event)
                try stepDone(statement)
            }
            try withStatement("""
                UPDATE monitor_state SET last_committed_event_id = MAX(last_committed_event_id, ?),
                    pending = CASE WHEN last_seen_event_id > ? THEN 1 ELSE 0 END,
                    needs_full_scan = CASE WHEN last_seen_event_id > ? THEN needs_full_scan ELSE 0 END,
                    updated_at = ? WHERE repository_id = ?
                """) { statement in
                    sqlite3_bind_int64(statement, 1, event)
                    sqlite3_bind_int64(statement, 2, event)
                    sqlite3_bind_int64(statement, 3, event)
                    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                    bind(repositoryID.uuidString, at: 5, in: statement)
                    try stepDone(statement)
                }
            return try monitorState(repositoryID: repositoryID)
                ?? RepositoryMonitorState(lastSeenEventID: eventID, lastCommittedEventID: eventID, hasPendingEvents: false, needsFullScan: false)
        }
    }

    func recordAgentError(repositoryID: UUID, message: String) throws -> AgentHealth {
        let health = AgentHealth(errorID: UUID(), message: message, updatedAt: .now)
        try withStatement("""
            INSERT INTO agent_errors(repository_id, error_id, message, updated_at) VALUES(?, ?, ?, ?)
            ON CONFLICT(repository_id) DO UPDATE SET error_id=excluded.error_id, message=excluded.message, updated_at=excluded.updated_at
            """) { statement in
                bind(repositoryID.uuidString, at: 1, in: statement)
                bind(health.errorID.uuidString, at: 2, in: statement)
                bind(message, at: 3, in: statement)
                sqlite3_bind_double(statement, 4, health.updatedAt.timeIntervalSince1970)
                try stepDone(statement)
            }
        return health
    }

    func clearAgentError(repositoryID: UUID) throws {
        try withStatement("DELETE FROM agent_errors WHERE repository_id = ?") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    func agentHealth() throws -> AgentHealth? {
        try withStatement("SELECT error_id, message, updated_at FROM agent_errors ORDER BY updated_at DESC LIMIT 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let id = UUID(uuidString: text(statement, 0)) else { return nil }
            return AgentHealth(errorID: id, message: text(statement, 1), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)))
        }
    }

    private func monitorIdentity(repositoryID: UUID) throws -> (volumeID: String, rootID: String)? {
        try withStatement("SELECT volume_id, root_id FROM monitor_state WHERE repository_id = ?") { statement in
            bind(repositoryID.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (text(statement, 0), text(statement, 1))
        }
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if text(statement, 1) == column { return true }
            }
            return false
        }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func withStatement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Data?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func optionalData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> Error {
        let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "SQLite error"
        return NSError(domain: "Durepo.SQLite", code: Int(database.map(sqlite3_errcode) ?? SQLITE_ERROR), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
