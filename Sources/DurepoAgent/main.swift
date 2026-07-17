import CoreServices
import DurepoCore
import Foundation
import OSLog

private let logger = Logger(subsystem: "st.rio.Durepo", category: "agent")

struct DurepoAgentMain {
    static func run() async {
        do {
            let storageURL = try DurepoEnvironment.defaultStorageURL()
            let coordinator = AgentCoordinator(storageURL: storageURL)
            try await coordinator.refreshRegistrations()
            logger.info("Durepo agent started")

            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(30))
                try await coordinator.refreshRegistrations()
            }
        } catch is CancellationError {
            logger.info("Durepo agent stopped")
        } catch {
            logger.fault("Agent terminated: \(error.localizedDescription, privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }
}

private actor AgentCoordinator {
    private let registry: RepositoryRegistry
    private let store: SnapshotStore
    private var sessions: [UUID: RepositorySession] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var burstStartedAt: [UUID: ContinuousClock.Instant] = [:]
    private var snapshotting: Set<UUID> = []

    init(storageURL: URL) {
        registry = RepositoryRegistry(storageURL: storageURL)
        store = SnapshotStore(storageURL: storageURL)
    }

    func refreshRegistrations() async throws {
        let records = try await registry.records().filter(\.isEnabled)
        updateSessions(records)
    }

    private func updateSessions(_ records: [RepositoryRecord]) {
        let activeIDs = Set(records.map(\.id))
        for id in sessions.keys where !activeIDs.contains(id) {
            sessions.removeValue(forKey: id)
            debounceTasks.removeValue(forKey: id)?.cancel()
            burstStartedAt.removeValue(forKey: id)
        }

        for record in records where sessions[record.id] == nil {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: record.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                guard url.startAccessingSecurityScopedResource() else {
                    throw DurepoError.bookmarkAccessDenied
                }
                let watcher = try FSEventWatcher(url: url) { [weak self] in
                    guard let self else { return }
                    Task { await self.scheduleSnapshot(for: record.id) }
                }
                sessions[record.id] = RepositorySession(record: record, url: url, watcher: watcher)
                logger.info("Monitoring \(record.displayName, privacy: .private)")
            } catch {
                logger.error("Unable to monitor \(record.displayName, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func scheduleSnapshot(for repositoryID: UUID) {
        let clock = ContinuousClock()
        let now = clock.now
        if let startedAt = burstStartedAt[repositoryID],
           startedAt.duration(to: now) >= .seconds(10) {
            debounceTasks.removeValue(forKey: repositoryID)?.cancel()
            burstStartedAt.removeValue(forKey: repositoryID)
            Task { [weak self] in await self?.createSnapshot(for: repositoryID) }
            return
        }
        if burstStartedAt[repositoryID] == nil {
            burstStartedAt[repositoryID] = now
        }
        debounceTasks[repositoryID]?.cancel()
        debounceTasks[repositoryID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                await self?.finishDebouncedSnapshot(for: repositoryID)
            } catch {
                // A newer event superseded this debounce task.
            }
        }
    }

    private func finishDebouncedSnapshot(for repositoryID: UUID) async {
        debounceTasks.removeValue(forKey: repositoryID)
        burstStartedAt.removeValue(forKey: repositoryID)
        await createSnapshot(for: repositoryID)
    }

    private func createSnapshot(for repositoryID: UUID) async {
        guard !snapshotting.contains(repositoryID), let session = sessions[repositoryID] else { return }
        snapshotting.insert(repositoryID)
        defer { snapshotting.remove(repositoryID) }
        do {
            let manifest = try await store.createSnapshot(
                repositoryURL: session.url,
                repositoryID: session.record.id,
                reason: .fileSystemEvent
            )
            logger.info("Created snapshot \(manifest.id.uuidString, privacy: .public)")
        } catch {
            logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class RepositorySession: @unchecked Sendable {
    let record: RepositoryRecord
    let url: URL
    let watcher: FSEventWatcher

    init(record: RepositoryRecord, url: URL, watcher: FSEventWatcher) {
        self.record = record
        self.url = url
        self.watcher = watcher
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}

private final class FSEventWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) throws {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, contextInfo, eventCount, _, eventFlags, _ in
                guard let contextInfo else { return }
                let watcher = Unmanaged<FSEventWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
                let flags = UnsafeBufferPointer(start: eventFlags, count: eventCount)
                if flags.contains(where: { flag in
                    flag & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemCreated
                            | kFSEventStreamEventFlagItemRemoved
                            | kFSEventStreamEventFlagItemRenamed
                            | kFSEventStreamEventFlagItemModified
                            | kFSEventStreamEventFlagMustScanSubDirs
                            | kFSEventStreamEventFlagRootChanged
                    ) != 0
                }) {
                    watcher.onChange()
                }
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "st.rio.Durepo.fsevents", qos: .utility))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw CocoaError(.fileReadUnknown)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

Task {
    await DurepoAgentMain.run()
}
dispatchMain()
