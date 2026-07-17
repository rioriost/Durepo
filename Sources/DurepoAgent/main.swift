import CoreServices
import DurepoCore
import Foundation
import OSLog
import UserNotifications

private let logger = Logger(subsystem: "st.rio.Durepo", category: "agent")

struct DurepoAgentMain {
    static func run() async {
        do {
            let storageURL = try DurepoEnvironment.defaultStorageURL()
            let coordinator = AgentCoordinator(storageURL: storageURL)
            try await coordinator.refreshRegistrations()
            logger.info("Durepo agent started")

            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
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
        await updateSessions(records)
    }

    private func updateSessions(_ records: [RepositoryRecord]) async {
        let activeIDs = Set(records.map(\.id))
        for id in sessions.keys where !activeIDs.contains(id) {
            sessions.removeValue(forKey: id)
            debounceTasks.removeValue(forKey: id)?.cancel()
            burstStartedAt.removeValue(forKey: id)
        }

        for record in records where sessions[record.id] == nil {
            do {
                let (agentRecord, url) = try await resolveRepository(record)
                let identity = try repositoryIdentity(at: url)
                let state = try await store.prepareMonitor(
                    repositoryID: record.id,
                    volumeID: identity.volumeID,
                    rootID: identity.rootID
                )
                let sinceWhen = state.lastCommittedEventID == 0
                    ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                    : FSEventStreamEventId(state.lastCommittedEventID)
                let watcher = try FSEventWatcher(url: url, sinceWhen: sinceWhen) { [weak self] batch in
                    guard let self else { return }
                    Task { await self.record(batch, for: record.id) }
                }
                sessions[record.id] = RepositorySession(record: agentRecord, url: url, watcher: watcher)
                logger.info("Monitoring \(agentRecord.displayName, privacy: .private)")
                if state.hasPendingEvents || state.needsFullScan {
                    Task { [weak self] in await self?.createSnapshot(for: record.id) }
                }
            } catch {
                logger.error("Unable to monitor \(record.displayName, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func repositoryIdentity(at url: URL) throws -> (volumeID: String, rootID: String) {
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileResourceIdentifierKey])
        return (
            values.volumeUUIDString ?? "unknown-volume",
            values.fileResourceIdentifier.map { String(describing: $0) } ?? url.standardizedFileURL.path
        )
    }

    private func record(_ batch: FSEventBatch, for repositoryID: UUID) async {
        do {
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: batch.lastEventID,
                flags: batch.flags,
                needsFullScan: batch.needsFullScan,
                changedPaths: batch.changedPaths
            )
            scheduleSnapshot(for: repositoryID)
        } catch {
            await report(error, repositoryID: repositoryID)
        }
    }

    private func resolveRepository(_ record: RepositoryRecord) async throws -> (RepositoryRecord, URL) {
        var agentRecord = record
        let persistentBookmark: Data

        if let bookmark = record.agentBookmark {
            persistentBookmark = bookmark
        } else {
            guard let handoffBookmark = record.handoffBookmark else {
                throw DurepoError.bookmarkAccessDenied
            }
            var handoffIsStale = false
            let handoffURL = try URL(
                resolvingBookmarkData: handoffBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &handoffIsStale
            )
            defer { handoffURL.stopAccessingSecurityScopedResource() }

            persistentBookmark = try handoffURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            agentRecord.agentBookmark = persistentBookmark
            agentRecord.handoffBookmark = nil
            try await registry.update(agentRecord)
        }

        var persistentIsStale = false
        let url = try URL(
            resolvingBookmarkData: persistentBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &persistentIsStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw DurepoError.bookmarkAccessDenied
        }
        return (agentRecord, url)
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
        while !Task.isCancelled {
            do {
                let state = try await store.monitorState(repositoryID: repositoryID)
                let targetEventID = state?.lastSeenEventID ?? 0
                let changeSet = try await store.pendingChangeSet(
                    repositoryID: repositoryID,
                    through: targetEventID
                )
                let manifest = try await store.createSnapshot(
                    repositoryURL: session.url,
                    repositoryID: session.record.id,
                    reason: .fileSystemEvent,
                    changeSet: changeSet
                )
                let committed = try await store.commitEvents(repositoryID: repositoryID, through: targetEventID)
                try await store.clearAgentError(repositoryID: repositoryID)
                logger.info("Created snapshot \(manifest.id.uuidString, privacy: .public) through event \(targetEventID)")
                guard committed.hasPendingEvents else { return }
                logger.info("Changes arrived during snapshot; rescanning \(session.record.displayName, privacy: .private)")
            } catch {
                await report(error, repositoryID: repositoryID)
                scheduleRetry(for: repositoryID)
                return
            }
        }
    }

    private func scheduleRetry(for repositoryID: UUID) {
        debounceTasks[repositoryID]?.cancel()
        debounceTasks[repositoryID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.finishDebouncedSnapshot(for: repositoryID)
        }
    }

    private func report(_ error: Error, repositoryID: UUID) async {
        let message = error.localizedDescription
        logger.error("Snapshot failed for \(repositoryID.uuidString, privacy: .public): \(message, privacy: .public)")
        do {
            let health = try await store.recordAgentError(repositoryID: repositoryID, message: message)
            let content = UNMutableNotificationContent()
            content.title = "Durepo"
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "durepo-agent-\(health.errorID.uuidString)",
                content: content,
                trigger: nil
            )
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Unable to publish agent error: \(error.localizedDescription, privacy: .public)")
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

private struct FSEventBatch: Sendable {
    let lastEventID: UInt64
    let flags: UInt64
    let needsFullScan: Bool
    let changedPaths: [String]
}

private let mutationEventFlags: FSEventStreamEventFlags = [
    kFSEventStreamEventFlagItemCreated,
    kFSEventStreamEventFlagItemRemoved,
    kFSEventStreamEventFlagItemRenamed,
    kFSEventStreamEventFlagItemModified,
    kFSEventStreamEventFlagItemInodeMetaMod,
    kFSEventStreamEventFlagItemFinderInfoMod,
    kFSEventStreamEventFlagItemChangeOwner,
    kFSEventStreamEventFlagItemXattrMod,
    kFSEventStreamEventFlagMustScanSubDirs,
    kFSEventStreamEventFlagRootChanged,
    kFSEventStreamEventFlagUserDropped,
    kFSEventStreamEventFlagKernelDropped,
    kFSEventStreamEventFlagEventIdsWrapped,
].reduce(FSEventStreamEventFlags(0)) { $0 | FSEventStreamEventFlags($1) }

private let fullScanEventFlags: FSEventStreamEventFlags = [
    kFSEventStreamEventFlagMustScanSubDirs,
    kFSEventStreamEventFlagRootChanged,
    kFSEventStreamEventFlagUserDropped,
    kFSEventStreamEventFlagKernelDropped,
    kFSEventStreamEventFlagEventIdsWrapped,
].reduce(FSEventStreamEventFlags(0)) { $0 | FSEventStreamEventFlags($1) }

nonisolated(unsafe) private let durepoFSEventCallback: FSEventStreamCallback = {
    _, contextInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let contextInfo, eventCount > 0 else { return }
    let watcher = Unmanaged<FSEventWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
    let flagBuffer = UnsafeBufferPointer(start: eventFlags, count: eventCount)
    let idBuffer = UnsafeBufferPointer(start: eventIDs, count: eventCount)
    let pathBuffer = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var combinedFlags = FSEventStreamEventFlags(0)
    var lastRelevantEventID = FSEventStreamEventId(0)
    var changedPaths: Set<String> = []
    for index in 0..<eventCount {
        let flag = flagBuffer[index]
        let mustReconcile = flag & fullScanEventFlags != 0
        let path = pathBuffer[index].map(String.init(cString:)) ?? ""
        if mustReconcile {
            changedPaths.insert("")
        } else {
            guard let relativePath = watcher.relativePath(for: path) else { continue }
            changedPaths.insert(relativePath)
        }
        combinedFlags |= flag
        lastRelevantEventID = max(lastRelevantEventID, idBuffer[index])
    }
    guard combinedFlags & mutationEventFlags != 0 else { return }
    watcher.deliver(FSEventBatch(
        lastEventID: UInt64(lastRelevantEventID),
        flags: UInt64(combinedFlags),
        needsFullScan: combinedFlags & fullScanEventFlags != 0,
        changedPaths: changedPaths.sorted()
    ))
}

private final class FSEventWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable (FSEventBatch) -> Void
    private let rootPath: String
    private let excludedDirectoryNames = DurepoConstants.defaultExcludedDirectoryNames

    init(
        url: URL,
        sinceWhen: FSEventStreamEventId,
        onChange: @escaping @Sendable (FSEventBatch) -> Void
    ) throws {
        self.onChange = onChange
        rootPath = url.standardizedFileURL.path
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
            durepoFSEventCallback,
            &context,
            [url.path] as CFArray,
            sinceWhen,
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

    func deliver(_ batch: FSEventBatch) { onChange(batch) }

    func relativePath(for path: String) -> String? {
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = path.dropFirst(rootPath.count + 1)
        guard !relative.isEmpty else { return "" }
        let isExcluded = relative.split(separator: "/").contains {
            excludedDirectoryNames.contains(String($0))
        }
        return isExcluded ? nil : String(relative)
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
