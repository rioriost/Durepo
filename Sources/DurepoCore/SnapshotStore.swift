import CryptoKit
import Darwin
import Foundation
import OSLog

public actor SnapshotStore {
    private static let performanceLog = OSLog(subsystem: "st.rio.Durepo", category: "snapshot")
    private static let performanceLogger = Logger(subsystem: "st.rio.Durepo", category: "snapshot")

    public let storageURL: URL
    private let objectsURL: URL
    private let manifestsURL: URL
    private let temporaryURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let defaultExclusionRules: ExclusionRuleSet
    private let retentionLimit: Int
    private let staleTemporaryAge: TimeInterval
    private let maxConcurrentFileOperations: Int
    private let smallFileThreshold: Int64
    private let cloneFilesWhenSupported: Bool
    private let maximumStorageByteCount: Int64
    private var metadata: SQLiteMetadata?
    private var didReconcileMetadata = false
    private var didCleanTemporaryFiles = false

    public init(
        storageURL: URL,
        fileManager: FileManager = .default,
        excludedDirectoryNames: Set<String> = DurepoConstants.defaultExcludedDirectoryNames,
        retentionLimit: Int = 50,
        staleTemporaryAge: TimeInterval = 3_600,
        maxConcurrentFileOperations: Int = 4,
        smallFileThreshold: Int64 = 4 * 1_048_576,
        cloneFilesWhenSupported: Bool = true,
        maximumStorageByteCount: Int64 = 50 * 1_073_741_824
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.objectsURL = storageURL.appending(path: "objects", directoryHint: .isDirectory)
        self.manifestsURL = storageURL.appending(path: "manifests", directoryHint: .isDirectory)
        self.temporaryURL = storageURL.appending(path: "temp", directoryHint: .isDirectory)
        self.lockURL = storageURL.appending(path: ".store.lock")
        self.fileManager = fileManager
        self.defaultExclusionRules = ExclusionRuleSet(excludedDirectoryNames)
        self.retentionLimit = max(1, retentionLimit)
        self.staleTemporaryAge = staleTemporaryAge
        self.maxConcurrentFileOperations = max(1, min(4, maxConcurrentFileOperations))
        self.smallFileThreshold = min(max(0, smallFileThreshold), 64 * 1_048_576)
        self.cloneFilesWhenSupported = cloneFilesWhenSupported
        self.maximumStorageByteCount = max(1_048_576, maximumStorageByteCount)
    }

    public func prepare() throws {
        for directory in [storageURL, objectsURL, manifestsURL, temporaryURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !didCleanTemporaryFiles {
            try removeStaleTemporaryFiles()
            didCleanTemporaryFiles = true
        }
        if metadata == nil {
            metadata = try SQLiteMetadata(url: storageURL.appending(path: "metadata.sqlite"))
        }
        if !didReconcileMetadata {
            try reconcileMetadata()
            didReconcileMetadata = true
        }
    }

    public func createSnapshot(
        repositoryURL: URL,
        repositoryID: UUID,
        reason: SnapshotReason,
        changeSet: SnapshotChangeSet? = nil,
        exclusionRules: ExclusionRuleSet? = nil,
        detectAnomalies: Bool = false,
        requiresRegisteredRepository: Bool = false,
        progress: (@Sendable (SnapshotProgress) -> Void)? = nil
    ) async throws -> SnapshotManifest {
        try prepare()
        let lockDescriptor = try acquireExclusiveStoreLock()
        defer { releaseStoreLock(lockDescriptor) }
        if requiresRegisteredRepository {
            let records = try await RepositoryRegistry(storageURL: storageURL).records()
            guard records.contains(where: { $0.id == repositoryID && $0.isEnabled }) else {
                throw DurepoError.repositoryNotRegistered
            }
        }

        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "CreateSnapshot", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.performanceLog, name: "CreateSnapshot", signpostID: signpostID) }
        let startedAt = ContinuousClock.now

        let root = repositoryURL.resolvingSymlinksInPath().standardizedFileURL
        let storage = storageURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DurepoError.invalidRepository(root.path)
        }
        guard !storage.isDescendant(of: root) else { throw DurepoError.storageInsideRepository }
        guard !root.isDescendant(of: storage) else { throw DurepoError.repositoryInsideStorage }

        let requestedIncremental = reason == .fileSystemEvent && changeSet?.needsFullScan == false
        let effectiveExclusionRules = exclusionRules ?? defaultExclusionRules
        let previousEntries = try metadataStore.currentEntries(repositoryID: repositoryID)
        let cachedEntries = requestedIncremental ? previousEntries : nil
        let usesFullScan = !requestedIncremental || cachedEntries == nil
        let scanStartedAt = ContinuousClock.now
        var work: SnapshotWork
        if usesFullScan {
            work = try collectHierarchy(
                at: root,
                root: root,
                includeTopLevelItem: false,
                exclusionRules: effectiveExclusionRules
            )
        } else {
            work = try collectIncrementalChanges(
                at: root,
                cachedEntries: cachedEntries ?? [:],
                changedPaths: changeSet?.changedPaths ?? [],
                exclusionRules: effectiveExclusionRules
            )
        }
        let scanDuration = scanStartedAt.duration(to: .now)
        let candidateBytes = work.fileCandidates.reduce(Int64(0)) { $0 + $1.fingerprint.size }
        try ensureStorageCapacity(for: candidateBytes)
        let captureStartedAt = ContinuousClock.now
        let captured = try await captureFiles(work.fileCandidates, progress: progress)
        let captureDuration = captureStartedAt.duration(to: .now)
        for result in captured {
            work.entries[result.indexedEntry.entry.relativePath] = result.indexedEntry
        }

        let indexedEntries = work.entries.values.sorted { $0.entry.relativePath < $1.entry.relativePath }
        let anomaly = detectAnomalies
            ? Self.detectAnomaly(previousEntries: previousEntries, currentEntries: indexedEntries)
            : nil

        let manifest = SnapshotManifest(
            repositoryID: repositoryID,
            repositoryName: root.lastPathComponent,
            reason: reason,
            entries: indexedEntries.map(\.entry),
            warnings: work.warnings
        )
        let manifestURL = manifestsURL.appending(path: "\(manifest.id.uuidString).json")
        try AtomicFileWriter.write(JSONEncoder.durepo.encode(manifest), to: manifestURL, fileManager: fileManager)
        try metadataStore.commitSnapshot(
            manifest,
            manifestFile: manifestURL.lastPathComponent,
            currentEntries: indexedEntries,
            anomaly: anomaly
        )
        try applyRetention(to: repositoryID)
        try applyCapacityRetention()

        let totalDuration = startedAt.duration(to: .now)
        let clones = captured.lazy.filter { $0.method == .clone }.count
        let memoryCopies = captured.lazy.filter { $0.method == .memory }.count
        let streams = captured.count - clones - memoryCopies
        Self.performanceLogger.info(
            "snapshot complete full=\(usesFullScan, privacy: .public) paths=\(changeSet?.changedPaths.count ?? 0, privacy: .public) files=\(manifest.fileCount, privacy: .public) captured=\(captured.count, privacy: .public) clone=\(clones, privacy: .public) memory=\(memoryCopies, privacy: .public) stream=\(streams, privacy: .public) scan_ms=\(scanDuration.milliseconds, privacy: .public) capture_ms=\(captureDuration.milliseconds, privacy: .public) total_ms=\(totalDuration.milliseconds, privacy: .public)"
        )
        return manifest
    }

    public func snapshotSummaries(repositoryID: UUID? = nil, limit: Int = 200) throws -> [SnapshotSummary] {
        try prepare()
        return try metadataStore.summaries(repositoryID: repositoryID, limit: max(1, limit))
    }

    public func snapshotDiff(id: UUID, offset: Int = 0, limit: Int = 500) throws -> SnapshotDiffPage {
        try prepare()
        return try metadataStore.snapshotDiff(snapshotID: id, offset: offset, limit: limit)
    }

    public func snapshotEntries(id: UUID, offset: Int = 0, limit: Int = 500) throws -> SnapshotDiffPage {
        try prepare()
        return try metadataStore.snapshotEntries(snapshotID: id, offset: offset, limit: limit)
    }

    public func manifest(id: UUID) throws -> SnapshotManifest {
        try prepare()
        guard let file = try metadataStore.manifestFile(id: id) else {
            throw DurepoError.corruptManifest(id.uuidString)
        }
        let url = manifestsURL.appending(path: file)
        do {
            return try JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        } catch {
            throw DurepoError.corruptManifest(url.path)
        }
    }

    @discardableResult
    public func deleteSnapshots(
        repositoryID: UUID,
        mode: SnapshotDeletionMode
    ) throws -> SnapshotDeletionResult {
        try prepare()
        let lockDescriptor = try acquireExclusiveStoreLock()
        defer { releaseStoreLock(lockDescriptor) }

        let manifestFiles = try metadataStore.manifestFiles(repositoryID: repositoryID)
        let manifestFileSet = Set(manifestFiles)
        var hashesToConsider: Set<String> = []
        var hashesStillReferenced: Set<String> = []

        if mode == .purgeUnreferencedObjects {
            for file in manifestFiles {
                let manifest = try decodeManifestFile(file)
                hashesToConsider.formUnion(validContentHashes(in: manifest))
            }
            hashesStillReferenced = try referencedContentHashes(excluding: manifestFileSet)
        }

        try metadataStore.deleteRepositoryData(repositoryID: repositoryID)
        for file in manifestFiles {
            let url = manifestsURL.appending(path: file)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                guard !fileManager.fileExists(atPath: url.path) else { throw error }
            }
        }
        if !manifestFiles.isEmpty { try Self.synchronizeDirectory(manifestsURL) }

        var deletedObjectCount = 0
        if mode == .purgeUnreferencedObjects {
            var modifiedObjectDirectories: Set<URL> = []
            for hash in hashesToConsider.subtracting(hashesStillReferenced) {
                let url = objectURL(for: hash)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    deletedObjectCount += 1
                    modifiedObjectDirectories.insert(url.deletingLastPathComponent())
                } catch {
                    guard !fileManager.fileExists(atPath: url.path) else { throw error }
                }
            }
            for directory in modifiedObjectDirectories {
                try Self.synchronizeDirectory(directory)
            }
        }

        return SnapshotDeletionResult(
            deletedSnapshotCount: manifestFiles.count,
            deletedObjectCount: deletedObjectCount
        )
    }

    public func prepareMonitor(repositoryID: UUID, volumeID: String, rootID: String) throws -> RepositoryMonitorState {
        try prepare()
        return try metadataStore.prepareMonitor(repositoryID: repositoryID, volumeID: volumeID, rootID: rootID)
    }

    public func recordEvent(
        repositoryID: UUID,
        eventID: UInt64,
        flags: UInt64,
        needsFullScan: Bool,
        changedPaths: [String] = []
    ) throws {
        try prepare()
        try metadataStore.recordEvent(
            repositoryID: repositoryID,
            eventID: eventID,
            flags: flags,
            needsFullScan: needsFullScan,
            changedPaths: changedPaths
        )
    }

    public func requireFullScan(repositoryID: UUID) throws {
        try prepare()
        try metadataStore.requireFullScan(repositoryID: repositoryID)
    }

    public func pendingChangeSet(repositoryID: UUID, through eventID: UInt64) throws -> SnapshotChangeSet {
        try prepare()
        return try metadataStore.pendingChangeSet(repositoryID: repositoryID, through: eventID)
    }

    public func monitorState(repositoryID: UUID) throws -> RepositoryMonitorState? {
        try prepare()
        return try metadataStore.monitorState(repositoryID: repositoryID)
    }

    public func commitEvents(repositoryID: UUID, through eventID: UInt64) throws -> RepositoryMonitorState {
        try prepare()
        return try metadataStore.commitEvents(repositoryID: repositoryID, through: eventID)
    }

    @discardableResult
    public func recordAgentError(repositoryID: UUID, message: String) throws -> AgentHealth {
        try prepare()
        return try metadataStore.recordAgentError(repositoryID: repositoryID, message: message)
    }

    public func clearAgentError(repositoryID: UUID) throws {
        try prepare()
        try metadataStore.clearAgentError(repositoryID: repositoryID)
    }

    public func agentHealth() throws -> AgentHealth? {
        try prepare()
        return try metadataStore.agentHealth()
    }

    public func protectionAlerts(includeAcknowledged: Bool = false) throws -> [ProtectionAlert] {
        try prepare()
        return try metadataStore.protectionAlerts(includeAcknowledged: includeAcknowledged)
    }

    public func acknowledgeProtectionAlert(id: UUID) throws {
        try prepare()
        try metadataStore.acknowledgeProtectionAlert(id: id)
    }

    public func setSnapshotProtected(id: UUID, isProtected: Bool) throws {
        try prepare()
        try metadataStore.setSnapshotProtected(id: id, isProtected: isProtected)
    }

    public func hasRestoreSuppression(repositoryID: UUID) throws -> Bool {
        try prepare()
        return try metadataStore.hasRestoreSuppression(repositoryID: repositoryID)
    }

    public func clearRestoreSuppression(repositoryID: UUID) throws {
        try prepare()
        try metadataStore.clearRestoreSuppression(repositoryID: repositoryID)
    }

    public func restoreInPlace(
        snapshotID: UUID,
        repositoryURL: URL,
        repositoryID: UUID,
        exclusionRules: ExclusionRuleSet,
        requiresRegisteredRepository: Bool = false
    ) async throws -> InPlaceRestoreResult {
        if try hasGitLockFile(in: repositoryURL) {
            throw DurepoError.gitOperationInProgress
        }
        let targetManifest = try manifest(id: snapshotID)
        guard targetManifest.repositoryID == repositoryID else {
            throw DurepoError.invalidRepository(repositoryURL.path)
        }
        try verify(targetManifest)
        try metadataStore.setSnapshotProtected(id: snapshotID, isProtected: true)
        let preRestoreSnapshot = try await createSnapshot(
            repositoryURL: repositoryURL,
            repositoryID: repositoryID,
            reason: .preRestore,
            exclusionRules: exclusionRules,
            requiresRegisteredRepository: requiresRegisteredRepository
        )
        let restoredURL = try await SnapshotRestorer(store: self)
            .replaceExistingDirectory(with: targetManifest, at: repositoryURL)
        try metadataStore.markRestoreCompleted(repositoryID: repositoryID)
        try metadataStore.requireFullScan(repositoryID: repositoryID)
        return InPlaceRestoreResult(restoredURL: restoredURL, preRestoreSnapshot: preRestoreSnapshot)
    }

    @discardableResult
    public func recordProtectionAlert(
        repositoryID: UUID,
        anomaly: RepositoryAnomaly
    ) throws -> ProtectionAlert {
        try prepare()
        return try metadataStore.recordProtectionAlert(repositoryID: repositoryID, anomaly: anomaly)
    }

    public func verify(_ manifest: SnapshotManifest) throws {
        guard manifest.formatVersion == DurepoConstants.formatVersion else {
            throw DurepoError.unsupportedFormat(manifest.formatVersion)
        }
        try verify(entries: manifest.entries)
    }

    public func verify(entries: [SnapshotEntry]) throws {
        for entry in entries where entry.kind == .file {
            guard let hash = entry.contentHash else {
                throw DurepoError.missingObject(entry.relativePath)
            }
            let url = objectURL(for: hash)
            guard fileManager.fileExists(atPath: url.path) else {
                throw DurepoError.missingObject(hash)
            }
            let actualHash = try Self.hashFile(at: url)
            guard actualHash == hash else { throw DurepoError.missingObject(hash) }
        }
    }

    public func objectURL(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return objectsURL
            .appending(path: prefix, directoryHint: .isDirectory)
            .appending(path: hash)
    }

    public func checkIntegrity(deep: Bool = true) throws -> StoreIntegrityReport {
        try prepare()
        let lockDescriptor = try acquireExclusiveStoreLock()
        defer { releaseStoreLock(lockDescriptor) }

        var issues: [IntegrityIssue] = []
        let databaseMessages = try metadataStore.integrityMessages()
        for message in databaseMessages where message.lowercased() != "ok" {
            issues.append(IntegrityIssue(severity: .error, message: "SQLite: \(message)"))
        }

        let manifestURLs = try fileManager.contentsOfDirectory(at: manifestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var referencedHashes: Set<String> = []
        for url in manifestURLs {
            let manifest: SnapshotManifest
            do {
                manifest = try JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: url))
            } catch {
                issues.append(IntegrityIssue(severity: .error, message: "Corrupt manifest: \(url.lastPathComponent)"))
                continue
            }
            for message in Self.manifestPathIssues(manifest.entries) {
                issues.append(IntegrityIssue(
                    severity: .error,
                    message: "Unsafe manifest \(url.lastPathComponent): \(message)"
                ))
            }
            for entry in manifest.entries where entry.kind == .file {
                guard let hash = entry.contentHash, Self.isValidContentHash(hash) else {
                    issues.append(IntegrityIssue(severity: .error, message: "Invalid object reference: \(entry.relativePath)"))
                    continue
                }
                guard referencedHashes.insert(hash).inserted else { continue }
                let object = objectURL(for: hash)
                guard fileManager.fileExists(atPath: object.path) else {
                    issues.append(IntegrityIssue(severity: .error, message: "Missing object: \(hash)"))
                    continue
                }
                if deep, try Self.hashFile(at: object) != hash {
                    issues.append(IntegrityIssue(severity: .error, message: "Object hash mismatch: \(hash)"))
                }
            }
        }

        let storedObjects = try storedObjectURLs()
        let orphanCount = storedObjects.lazy.filter { !referencedHashes.contains($0.lastPathComponent) }.count
        if orphanCount > 0 {
            issues.append(IntegrityIssue(
                severity: .warning,
                message: "\(orphanCount) unreferenced objects can be reclaimed."
            ))
        }
        let availableCapacity = try? storageURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        return StoreIntegrityReport(
            snapshotCount: manifestURLs.count,
            referencedObjectCount: referencedHashes.count,
            storedObjectCount: storedObjects.count,
            orphanObjectCount: orphanCount,
            availableCapacity: availableCapacity,
            issues: issues
        )
    }

    public func garbageCollect() throws -> GarbageCollectionResult {
        try prepare()
        let lockDescriptor = try acquireExclusiveStoreLock()
        defer { releaseStoreLock(lockDescriptor) }
        guard try metadataStore.integrityMessages().allSatisfy({ $0.lowercased() == "ok" }),
              try !metadataStore.hasAnyActiveProtectionAlert() else {
            throw DurepoError.garbageCollectionUnsafe
        }
        return try garbageCollectUnlocked()
    }

    private func garbageCollectUnlocked() throws -> GarbageCollectionResult {
        let referenced = try referencedContentHashes(excluding: [])
        var deletedCount = 0
        var reclaimedBytes: Int64 = 0
        var modifiedDirectories: Set<URL> = []
        for url in try storedObjectURLs() where !referenced.contains(url.lastPathComponent) {
            let info = try url.lstatInfo()
            try fileManager.removeItem(at: url)
            deletedCount += 1
            reclaimedBytes += Int64(info.st_blocks) * 512
            modifiedDirectories.insert(url.deletingLastPathComponent())
        }
        for directory in modifiedDirectories { try Self.synchronizeDirectory(directory) }
        return GarbageCollectionResult(
            deletedObjectCount: deletedCount,
            reclaimedByteCount: reclaimedBytes
        )
    }

    private func decodeManifestFile(_ file: String) throws -> SnapshotManifest {
        let url = manifestsURL.appending(path: file)
        do {
            return try JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        } catch {
            throw DurepoError.corruptManifest(url.path)
        }
    }

    private func storedObjectURLs() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: objectsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard Self.isValidContentHash(url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(url)
        }
        return result
    }

    private func hasGitLockFile(in repositoryURL: URL) throws -> Bool {
        let gitURL = repositoryURL.appending(path: ".git", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: gitURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              ) else { return false }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".lock") {
            return true
        }
        return false
    }

    private func ensureStorageCapacity(for candidateBytes: Int64) throws {
        let values = try storageURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let reserve: Int64 = 256 * 1_048_576
        let expectedGrowth = min(max(0, candidateBytes), 1_073_741_824)
        guard available >= reserve + expectedGrowth else {
            throw DurepoError.insufficientStorage(available: available, required: reserve + expectedGrowth)
        }
    }

    private func storageAllocatedByteCount() throws -> Int64 {
        try storedObjectURLs().reduce(Int64(0)) { total, url in
            total + Int64(try url.lstatInfo().st_blocks) * 512
        }
    }

    private func applyCapacityRetention() throws {
        var allocated = try storageAllocatedByteCount()
        while allocated > maximumStorageByteCount {
            guard let manifestFile = try metadataStore.pruneOldestCapacityCandidate() else { return }
            let manifestURL = manifestsURL.appending(path: manifestFile)
            if fileManager.fileExists(atPath: manifestURL.path) {
                try fileManager.removeItem(at: manifestURL)
                try Self.synchronizeDirectory(manifestsURL)
            }
            _ = try garbageCollectUnlocked()
            allocated = try storageAllocatedByteCount()
        }
    }

    private static func detectAnomaly(
        previousEntries: [String: IndexedSnapshotEntry]?,
        currentEntries: [IndexedSnapshotEntry]
    ) -> RepositoryAnomaly? {
        guard let previousEntries, !previousEntries.isEmpty else { return nil }
        let currentByPath = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.entry.relativePath, $0.entry) })
        let previousFiles = previousEntries.values.filter { $0.entry.kind == .file }
        let currentFiles = currentEntries.filter { $0.entry.kind == .file }

        let previouslyHadGit = previousEntries.keys.contains { $0 == ".git" || $0.hasPrefix(".git/") }
        let currentlyHasGit = currentByPath.keys.contains { $0 == ".git" || $0.hasPrefix(".git/") }
        if previouslyHadGit && !currentlyHasGit {
            return RepositoryAnomaly(
                kind: .gitDirectoryDeleted,
                message: "The .git directory disappeared. The last healthy snapshot was protected.",
                previousFileCount: previousFiles.count
            )
        }

        let removedFileCount = previousFiles.reduce(into: 0) { count, indexed in
            if currentByPath[indexed.entry.relativePath]?.kind != .file { count += 1 }
        }
        let previousFileCount = previousFiles.count
        let removalRatio = previousFileCount == 0 ? 0 : Double(removedFileCount) / Double(previousFileCount)
        if removedFileCount >= 1_000 || (removedFileCount >= 50 && removalRatio >= 0.35) {
            return RepositoryAnomaly(
                kind: .massDeletion,
                message: "A destructive change removed \(removedFileCount) of \(previousFileCount) files. The last healthy snapshot was protected.",
                removedFileCount: removedFileCount,
                previousFileCount: previousFileCount
            )
        }
        if previousFileCount >= 20, currentFiles.count * 2 <= previousFileCount, removedFileCount >= 20 {
            return RepositoryAnomaly(
                kind: .fileCountDrop,
                message: "The repository file count dropped from \(previousFileCount) to \(currentFiles.count). The last healthy snapshot was protected.",
                removedFileCount: removedFileCount,
                previousFileCount: previousFileCount
            )
        }

        let zeroedCount = previousFiles.reduce(into: 0) { count, indexed in
            guard indexed.entry.byteCount > 0,
                  let current = currentByPath[indexed.entry.relativePath],
                  current.kind == .file,
                  current.byteCount == 0 else { return }
            count += 1
        }
        if zeroedCount >= 50 || (previousFileCount >= 20 && zeroedCount * 2 >= previousFileCount) {
            return RepositoryAnomaly(
                kind: .massZeroByte,
                message: "A destructive change reduced \(zeroedCount) files to zero bytes. The last healthy snapshot was protected.",
                previousFileCount: previousFileCount
            )
        }
        return nil
    }

    private func referencedContentHashes(excluding excludedFiles: Set<String>) throws -> Set<String> {
        let urls = try fileManager.contentsOfDirectory(at: manifestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !excludedFiles.contains($0.lastPathComponent) }
        var hashes: Set<String> = []
        for url in urls {
            do {
                let manifest = try JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: url))
                hashes.formUnion(validContentHashes(in: manifest))
            } catch {
                throw DurepoError.corruptManifest(url.path)
            }
        }
        return hashes
    }

    private func validContentHashes(in manifest: SnapshotManifest) -> Set<String> {
        Set(manifest.entries.compactMap { entry in
            guard entry.kind == .file, let hash = entry.contentHash, Self.isValidContentHash(hash) else {
                return nil
            }
            return hash
        })
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!) ||
                ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }

    private static func manifestPathIssues(_ entries: [SnapshotEntry]) -> [String] {
        var issues: [String] = []
        let paths = entries.map(\.relativePath)
        if Set(paths).count != paths.count { issues.append("duplicate path") }
        let symbolicLinkPaths = entries.lazy.filter { $0.kind == .symbolicLink }.map(\.relativePath)
        for path in paths {
            if path.isEmpty || path.contains("\0") || (try? validateRelativeChangePath(path)) != path {
                issues.append(path)
            }
            if symbolicLinkPaths.contains(where: { path.hasPrefix($0 + "/") }) {
                issues.append("entry below symbolic link: \(path)")
            }
        }
        return issues
    }

    private func acquireExclusiveStoreLock() throws -> Int32 {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.posixError() }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            let error = Self.posixError()
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func releaseStoreLock(_ descriptor: Int32) {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }

    private func collectIncrementalChanges(
        at root: URL,
        cachedEntries: [String: IndexedSnapshotEntry],
        changedPaths: [String],
        exclusionRules: ExclusionRuleSet
    ) throws -> SnapshotWork {
        let paths = try minimizedChangedPaths(changedPaths)
        guard !paths.isEmpty, !paths.contains("") else {
            return try collectHierarchy(
                at: root,
                root: root,
                includeTopLevelItem: false,
                exclusionRules: exclusionRules
            )
        }

        var work = SnapshotWork(entries: cachedEntries)
        var candidatesByPath: [String: FileCandidate] = [:]
        var ancestors: Set<String> = []

        for relativePath in paths {
            let removedDirectory = cachedEntries[relativePath]?.entry.kind == .directory
            work.entries.removeValue(forKey: relativePath)
            if removedDirectory {
                work.entries = work.entries.filter { key, _ in
                    !key.hasPrefix(relativePath + "/")
                }
            }
            let wasDirectory = cachedEntries[relativePath]?.entry.kind == .directory
            guard !exclusionRules.excludes(relativePath, isDirectory: wasDirectory) else { continue }

            var parent = (relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                ancestors.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }

            let url = root.appending(path: relativePath)
            do {
                let changedWork = try collectHierarchy(
                    at: url,
                    root: root,
                    includeTopLevelItem: true,
                    exclusionRules: exclusionRules
                )
                work.entries.merge(changedWork.entries) { _, new in new }
                for candidate in changedWork.fileCandidates {
                    if candidate.relativePath != relativePath,
                       let cached = cachedEntries[candidate.relativePath],
                       cached.entry.kind == .file,
                       cached.entry.contentHash != nil,
                       cached.fingerprint == candidate.fingerprint {
                        work.entries[candidate.relativePath] = cached
                    } else {
                        candidatesByPath[candidate.relativePath] = candidate
                    }
                }
                work.warnings.append(contentsOf: changedWork.warnings)
            } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
                continue
            }
        }

        for relativePath in ancestors.sorted() where !exclusionRules.excludes(relativePath, isDirectory: true) {
            let url = root.appending(path: relativePath)
            guard let indexed = try? indexedNonFileEntry(at: url, root: root),
                  indexed.entry.kind == .directory else { continue }
            work.entries[relativePath] = indexed
        }
        work.fileCandidates = candidatesByPath.values.sorted { $0.relativePath < $1.relativePath }
        return work
    }

    private func collectHierarchy(
        at top: URL,
        root: URL,
        includeTopLevelItem: Bool,
        exclusionRules: ExclusionRuleSet
    ) throws -> SnapshotWork {
        var work = SnapshotWork()
        var topInfo: stat?
        if includeTopLevelItem {
            let info = try top.lstatInfo()
            topInfo = info
            let isDirectory = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            let relativePath = try top.safeRelativePath(from: root)
            if exclusionRules.excludes(relativePath, isDirectory: isDirectory) { return work }
            try collectItem(at: top, root: root, info: info, work: &work)
            if !isDirectory { return work }
        }

        if let topInfo, topInfo.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) { return work }
        guard let enumerator = fileManager.enumerator(
            at: top,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                work.warnings.append("\(url.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            throw DurepoError.invalidRepository(top.path)
        }

        for case let url as URL in enumerator {
            let info = try url.lstatInfo()
            let fileType = info.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            let relativePath = try url.safeRelativePath(from: root)
            if exclusionRules.excludes(relativePath, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            try collectItem(at: url, root: root, info: info, work: &work)
        }
        return work
    }

    private func collectItem(at url: URL, root: URL, info: stat, work: inout SnapshotWork) throws {
        let relativePath = try url.safeRelativePath(from: root)
        let fileType = info.st_mode & mode_t(S_IFMT)
        switch fileType {
        case mode_t(S_IFREG):
            work.fileCandidates.append(
                FileCandidate(url: url, relativePath: relativePath, fingerprint: FileFingerprint(info))
            )
        case mode_t(S_IFDIR), mode_t(S_IFLNK):
            work.entries[relativePath] = try indexedNonFileEntry(at: url, root: root, info: info)
        default:
            work.warnings.append("Unsupported special file skipped: \(relativePath)")
        }
    }

    private func indexedNonFileEntry(at url: URL, root: URL, info suppliedInfo: stat? = nil) throws -> IndexedSnapshotEntry {
        let info = try suppliedInfo ?? url.lstatInfo()
        let relativePath = try url.safeRelativePath(from: root)
        let fileType = info.st_mode & mode_t(S_IFMT)
        let kind: SnapshotEntryKind
        let linkDestination: String?
        if fileType == mode_t(S_IFDIR) {
            kind = .directory
            linkDestination = nil
        } else if fileType == mode_t(S_IFLNK) {
            kind = .symbolicLink
            linkDestination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        } else {
            throw DurepoError.unsupportedFile(url.path)
        }
        return IndexedSnapshotEntry(
            entry: SnapshotEntry(
                relativePath: relativePath,
                kind: kind,
                posixMode: UInt32(info.st_mode & 0o7777),
                modifiedAt: Self.modificationDate(info),
                symbolicLinkDestination: linkDestination,
                allocatedByteCount: Int64(info.st_blocks) * 512,
                extendedAttributes: try FileMetadata.extendedAttributes(
                    at: url,
                    noFollow: kind == .symbolicLink
                ),
                aclText: kind == .symbolicLink ? nil : try FileMetadata.aclText(at: url)
            ),
            fingerprint: FileFingerprint(info)
        )
    }

    private func minimizedChangedPaths(_ paths: [String]) throws -> [String] {
        let normalized = try Set(paths.map(Self.validateRelativeChangePath)).sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
        }
        var result: [String] = []
        for path in normalized {
            if path.isEmpty { return [""] }
            guard !result.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            result.append(path)
        }
        return result
    }

    private func captureFiles(
        _ candidates: [FileCandidate],
        progress: (@Sendable (SnapshotProgress) -> Void)?
    ) async throws -> [SnapshotCaptureResult] {
        guard !candidates.isEmpty else { return [] }
        let temporaryURL = temporaryURL
        let objectsURL = objectsURL
        let smallFileThreshold = smallFileThreshold
        let cloneFilesWhenSupported = cloneFilesWhenSupported
        let concurrency = min(maxConcurrentFileOperations, candidates.count)
        var iterator = candidates.makeIterator()
        var results: [SnapshotCaptureResult] = []
        results.reserveCapacity(candidates.count)
        var filesProcessed = 0
        var bytesProcessed: Int64 = 0

        return try await withThrowingTaskGroup(of: SnapshotCaptureResult.self) { group in
            func addNext() -> Bool {
                guard let candidate = iterator.next() else { return false }
                group.addTask(priority: .utility) {
                    try Self.captureFile(
                        candidate,
                        temporaryDirectory: temporaryURL,
                        objectsDirectory: objectsURL,
                        smallFileThreshold: smallFileThreshold,
                        cloneFilesWhenSupported: cloneFilesWhenSupported
                    )
                }
                return true
            }
            for _ in 0..<concurrency { _ = addNext() }
            while let result = try await group.next() {
                results.append(result)
                filesProcessed += 1
                bytesProcessed += result.indexedEntry.entry.byteCount
                progress?(SnapshotProgress(
                    filesProcessed: filesProcessed,
                    bytesProcessed: bytesProcessed,
                    currentPath: result.indexedEntry.entry.relativePath
                ))
                _ = addNext()
            }
            return results
        }
    }

    private static func captureFile(
        _ candidate: FileCandidate,
        temporaryDirectory: URL,
        objectsDirectory: URL,
        smallFileThreshold: Int64,
        cloneFilesWhenSupported: Bool
    ) throws -> SnapshotCaptureResult {
        for attempt in 0..<2 {
            let temporaryURL = temporaryDirectory.appending(path: "\(UUID().uuidString).object")
            do {
                return try captureFileAttempt(
                    candidate,
                    temporaryURL: temporaryURL,
                    objectsDirectory: objectsDirectory,
                    smallFileThreshold: smallFileThreshold,
                    cloneFilesWhenSupported: cloneFilesWhenSupported
                )
            } catch DurepoError.fileChangedDuringRead where attempt == 0 {
                try? FileManager.default.removeItem(at: temporaryURL)
                continue
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
        throw DurepoError.fileChangedDuringRead(candidate.url.path)
    }

    private static func captureFileAttempt(
        _ candidate: FileCandidate,
        temporaryURL: URL,
        objectsDirectory: URL,
        smallFileThreshold: Int64,
        cloneFilesWhenSupported: Bool
    ) throws -> SnapshotCaptureResult {
        let descriptor = Darwin.open(candidate.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else { throw posixError() }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DurepoError.unsupportedFile(candidate.url.path)
        }

        let hash: String
        let metadata: stat
        let method: SnapshotCaptureMethod
        let capturedExtendedAttributes = try FileMetadata.extendedAttributes(fileDescriptor: descriptor)
        let capturedACL = try FileMetadata.aclText(fileDescriptor: descriptor)
        let cloneBlockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        let canSafelyClone = before.st_flags & cloneBlockedFlags == 0
        if cloneFilesWhenSupported, canSafelyClone, try cloneFile(descriptor: descriptor, to: temporaryURL) {
            metadata = try temporaryURL.lstatInfo()
            try normalizeStoredFile(at: temporaryURL)
            hash = try hashFile(at: temporaryURL)
            try commitTemporaryObject(temporaryURL, hash: hash, objectsDirectory: objectsDirectory)
            method = .clone
        } else if Int64(before.st_size) <= smallFileThreshold {
            guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
            let data = try readAll(descriptor: descriptor, maximumSize: max(smallFileThreshold * 2, 1_048_576))
            var after = stat()
            guard Darwin.fstat(descriptor, &after) == 0 else { throw posixError() }
            try validateStable(before: before, after: after, byteCount: Int64(data.count), path: candidate.url.path)
            hash = SHA256.hash(data: data).hexString
            metadata = after
            try storeDataIfNeeded(data, temporaryURL: temporaryURL, hash: hash, objectsDirectory: objectsDirectory)
            method = .memory
        } else {
            guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
            let streamed = try streamToTemporaryObject(
                descriptor: descriptor,
                before: before,
                sourcePath: candidate.url.path,
                temporaryURL: temporaryURL
            )
            hash = streamed.hash
            metadata = streamed.info
            try commitTemporaryObject(temporaryURL, hash: hash, objectsDirectory: objectsDirectory)
            method = .streaming
        }

        let entry = SnapshotEntry(
            relativePath: candidate.relativePath,
            kind: .file,
            contentHash: hash,
            byteCount: Int64(metadata.st_size),
            posixMode: UInt32(metadata.st_mode & 0o7777),
            modifiedAt: modificationDate(metadata),
            hardLinkGroup: before.st_nlink > 1 ? "\(before.st_dev):\(before.st_ino)" : nil,
            allocatedByteCount: Int64(before.st_blocks) * 512,
            extendedAttributes: capturedExtendedAttributes,
            aclText: capturedACL
        )
        return SnapshotCaptureResult(
            indexedEntry: IndexedSnapshotEntry(entry: entry, fingerprint: FileFingerprint(before)),
            method: method
        )
    }

    private static func cloneFile(descriptor: Int32, to destination: URL) throws -> Bool {
        if Darwin.fclonefileat(descriptor, AT_FDCWD, destination.path, 0) == 0 { return true }
        let code = errno
        if [EXDEV, ENOTSUP, EINVAL, EPERM, EACCES, EDEADLK].contains(code) { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func readAll(descriptor: Int32, maximumSize: Int64) throws -> Data {
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var result = Data()
        while let data = try source.read(upToCount: 1_048_576), !data.isEmpty {
            guard Int64(result.count) + Int64(data.count) <= maximumSize else {
                throw DurepoError.fileChangedDuringRead("file grew during read")
            }
            result.append(data)
        }
        return result
    }

    private static func streamToTemporaryObject(
        descriptor: Int32,
        before: stat,
        sourcePath: String,
        temporaryURL: URL
    ) throws -> (hash: String, info: stat) {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try normalizeStoredFile(at: temporaryURL)
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let destination = try FileHandle(forWritingTo: temporaryURL)
        var hasher = SHA256()
        var byteCount: Int64 = 0
        do {
            while let data = try source.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
                try destination.write(contentsOf: data)
                byteCount += Int64(data.count)
            }
            try destination.synchronize()
            try destination.close()
        } catch {
            try? destination.close()
            throw error
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { throw posixError() }
        try validateStable(before: before, after: after, byteCount: byteCount, path: sourcePath)
        return (hasher.finalize().hexString, after)
    }

    private static func storeDataIfNeeded(
        _ data: Data,
        temporaryURL: URL,
        hash: String,
        objectsDirectory: URL
    ) throws {
        let destination = objectURL(for: hash, objectsDirectory: objectsDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try normalizeStoredFile(at: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try commitTemporaryObject(temporaryURL, hash: hash, objectsDirectory: objectsDirectory)
    }

    private static func commitTemporaryObject(_ temporaryURL: URL, hash: String, objectsDirectory: URL) throws {
        let fileManager = FileManager.default
        let destination = objectURL(for: hash, objectsDirectory: objectsDirectory)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: temporaryURL)
            return
        }
        try synchronizeFile(temporaryURL)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryURL)
            } else {
                throw error
            }
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private static func normalizeStoredFile(at url: URL) throws {
        try FileMetadata.removeExtendedAttributes(at: url)
        try FileMetadata.removeACL(at: url)
        guard Darwin.chflags(url.path, 0) == 0 else { throw posixError() }
        guard Darwin.chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw posixError() }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func validateStable(before: stat, after: stat, byteCount: Int64, path: String) throws {
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              byteCount == Int64(after.st_size) else {
            throw DurepoError.fileChangedDuringRead(path)
        }
    }

    private static func objectURL(for hash: String, objectsDirectory: URL) -> URL {
        objectsDirectory
            .appending(path: String(hash.prefix(2)), directoryHint: .isDirectory)
            .appending(path: hash)
    }

    private static func modificationDate(_ info: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func validateRelativeChangePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else { throw DurepoError.unsafeManifestPath(path) }
        if path.isEmpty { return "" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DurepoError.unsafeManifestPath(path)
        }
        return components.map(String.init).joined(separator: "/")
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }

    private var metadataStore: SQLiteMetadata {
        get throws {
            guard let metadata else { throw CocoaError(.fileReadUnknown) }
            return metadata
        }
    }

    private func reconcileMetadata() throws {
        let urls = try fileManager.contentsOfDirectory(at: manifestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let manifest = try JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: url))
                if try metadataStore.containsSnapshot(id: id) {
                    if !manifest.entries.isEmpty, try !metadataStore.containsSnapshotEntries(id: id) {
                        try metadataStore.indexEntries(manifest)
                    }
                } else {
                    try metadataStore.index(manifest, manifestFile: url.lastPathComponent)
                    try metadataStore.invalidateCurrentIndex(repositoryID: manifest.repositoryID)
                }
            } catch {
                throw DurepoError.corruptManifest(url.path)
            }
        }
        for repositoryID in try metadataStore.repositoryIDs() {
            try applyRetention(to: repositoryID)
        }
    }

    private func applyRetention(to repositoryID: UUID) throws {
        let files = try metadataStore.prune(repositoryID: repositoryID, keeping: retentionLimit)
        for file in files {
            let url = manifestsURL.appending(path: file)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                guard !fileManager.fileExists(atPath: url.path) else { throw error }
            }
        }
        if !files.isEmpty { try Self.synchronizeDirectory(manifestsURL) }
    }

    private func removeStaleTemporaryFiles() throws {
        let cutoff = Date().addingTimeInterval(-staleTemporaryAge)
        let urls = try fileManager.contentsOfDirectory(
            at: temporaryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if values.contentModificationDate.map({ $0 < cutoff }) ?? false {
                try fileManager.removeItem(at: url)
            }
        }
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct FileCandidate: Sendable {
    let url: URL
    let relativePath: String
    let fingerprint: FileFingerprint
}

private struct SnapshotWork {
    var entries: [String: IndexedSnapshotEntry]
    var fileCandidates: [FileCandidate]
    var warnings: [String]

    init(
        entries: [String: IndexedSnapshotEntry] = [:],
        fileCandidates: [FileCandidate] = [],
        warnings: [String] = []
    ) {
        self.entries = entries
        self.fileCandidates = fileCandidates
        self.warnings = warnings
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + Int64(parts.attoseconds / 1_000_000_000_000_000)
    }
}

extension URL {
    func safeRelativePath(from root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw DurepoError.unsafeManifestPath(path)
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard !relative.isEmpty else { throw DurepoError.unsafeManifestPath(path) }
        return relative
    }

    func isDescendant(of possibleAncestor: URL) -> Bool {
        let ancestorPath = possibleAncestor.standardizedFileURL.path
        let path = standardizedFileURL.path
        return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }

    func lstatInfo() throws -> stat {
        var result = stat()
        let status = path.withCString { Darwin.lstat($0, &result) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return result
    }
}
