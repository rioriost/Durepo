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
        try execute("""
            CREATE TABLE IF NOT EXISTS agent_errors (
                repository_id TEXT PRIMARY KEY,
                error_id TEXT NOT NULL,
                message TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("PRAGMA user_version=3")
    }

    deinit { sqlite3_close(database) }

    func index(_ manifest: SnapshotManifest, manifestFile: String) throws {
        try upsertSnapshot(manifest, manifestFile: manifestFile)
    }

    func commitSnapshot(
        _ manifest: SnapshotManifest,
        manifestFile: String,
        currentEntries: [IndexedSnapshotEntry]
    ) throws {
        try transaction {
            try upsertSnapshot(manifest, manifestFile: manifestFile)
            try withStatement("DELETE FROM current_entries WHERE repository_id = ?") { statement in
                bind(manifest.repositoryID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("""
                INSERT INTO current_entries(
                    repository_id, relative_path, kind, content_hash, byte_count, posix_mode,
                    modified_at, symbolic_link_destination, device, inode, file_size,
                    mtime_seconds, mtime_nanoseconds, ctime_seconds, ctime_nanoseconds
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        if let fingerprint = indexed.fingerprint {
                            sqlite3_bind_int64(statement, 9, Int64(bitPattern: fingerprint.device))
                            sqlite3_bind_int64(statement, 10, Int64(bitPattern: fingerprint.inode))
                            sqlite3_bind_int64(statement, 11, fingerprint.size)
                            sqlite3_bind_int64(statement, 12, fingerprint.modificationSeconds)
                            sqlite3_bind_int64(statement, 13, fingerprint.modificationNanoseconds)
                            sqlite3_bind_int64(statement, 14, fingerprint.statusSeconds)
                            sqlite3_bind_int64(statement, 15, fingerprint.statusNanoseconds)
                        } else {
                            for index in 9...15 { sqlite3_bind_null(statement, Int32(index)) }
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
                symbolic_link_destination, device, inode, file_size, mtime_seconds,
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
                        symbolicLinkDestination: optionalText(statement, 6)
                    )
                    let fingerprint: FileFingerprint?
                    if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                        fingerprint = nil
                    } else {
                        fingerprint = FileFingerprint(
                            device: UInt64(bitPattern: sqlite3_column_int64(statement, 7)),
                            inode: UInt64(bitPattern: sqlite3_column_int64(statement, 8)),
                            size: sqlite3_column_int64(statement, 9),
                            modificationSeconds: sqlite3_column_int64(statement, 10),
                            modificationNanoseconds: sqlite3_column_int64(statement, 11),
                            statusSeconds: sqlite3_column_int64(statement, 12),
                            statusNanoseconds: sqlite3_column_int64(statement, 13)
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

    private func upsertSnapshot(_ manifest: SnapshotManifest, manifestFile: String) throws {
        try withStatement("""
            INSERT INTO snapshots(id, repository_id, repository_name, created_at, reason, manifest_file, file_count, logical_byte_count)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                repository_id=excluded.repository_id,
                repository_name=excluded.repository_name,
                created_at=excluded.created_at,
                reason=excluded.reason,
                manifest_file=excluded.manifest_file,
                file_count=excluded.file_count,
                logical_byte_count=excluded.logical_byte_count
            """) { statement in
                bind(manifest.id.uuidString, at: 1, in: statement)
                bind(manifest.repositoryID.uuidString, at: 2, in: statement)
                bind(manifest.repositoryName, at: 3, in: statement)
                sqlite3_bind_double(statement, 4, manifest.createdAt.timeIntervalSince1970)
                bind(manifest.reason.rawValue, at: 5, in: statement)
                bind(manifestFile, at: 6, in: statement)
                sqlite3_bind_int64(statement, 7, Int64(manifest.fileCount))
                sqlite3_bind_int64(statement, 8, manifest.logicalByteCount)
                try stepDone(statement)
            }
    }

    func containsSnapshot(id: UUID) throws -> Bool {
        try withStatement("SELECT 1 FROM snapshots WHERE id = ? LIMIT 1") { statement in
            bind(id.uuidString, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func summaries(repositoryID: UUID?, limit: Int) throws -> [SnapshotSummary] {
        let filtered = repositoryID != nil
        let sql = """
            SELECT id, repository_id, repository_name, created_at, reason, file_count, logical_byte_count
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
                      let reason = SnapshotReason(rawValue: text(statement, 4)) else { continue }
                result.append(SnapshotSummary(
                    id: id,
                    repositoryID: repositoryID,
                    repositoryName: text(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    reason: reason,
                    fileCount: Int(sqlite3_column_int64(statement, 5)),
                    logicalByteCount: sqlite3_column_int64(statement, 6)
                ))
            }
            return result
        }
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
            for table in [
                "snapshots", "current_entries", "repository_indexes", "event_paths",
                "event_batches", "monitor_state", "agent_errors",
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

    func prune(repositoryID: UUID, keeping count: Int) throws -> [String] {
        return try transaction {
            let files = try withStatement("""
                SELECT manifest_file FROM snapshots WHERE repository_id = ?
                ORDER BY created_at DESC LIMIT -1 OFFSET ?
                """) { statement in
                    bind(repositoryID.uuidString, at: 1, in: statement)
                    sqlite3_bind_int64(statement, 2, Int64(count))
                    var result: [String] = []
                    while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
                    return result
                }
            try withStatement("""
                DELETE FROM snapshots WHERE id IN (
                    SELECT id FROM snapshots WHERE repository_id = ? ORDER BY created_at DESC LIMIT -1 OFFSET ?
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

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> Error {
        let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "SQLite error"
        return NSError(domain: "Durepo.SQLite", code: Int(database.map(sqlite3_errcode) ?? SQLITE_ERROR), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
