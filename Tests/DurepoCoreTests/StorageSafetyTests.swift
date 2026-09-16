import Darwin
import Foundation
import Testing
@testable import DurepoCore

@Suite("Storage safety")
struct StorageSafetyTests {
    @Test("GC waits for an in-flight snapshot instead of deleting its objects")
    func concurrentGarbageCollection() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("first", path: "a.txt")
        try fixture.write(String(repeating: "second", count: 100_000), path: "b.txt")
        let store = SnapshotStore(storageURL: fixture.storage, maxConcurrentFileOperations: 1)
        let trigger = AsyncStream<Void>.makeStream()
        let collection = Task {
            for await _ in trigger.stream { return try await store.garbageCollect() }
            throw CancellationError()
        }
        let snapshot = try await store.createSnapshot(
            repositoryURL: fixture.repository, repositoryID: UUID(), reason: .manual,
            progress: { progress in
                if progress.filesProcessed == 1 { trigger.continuation.yield(()) }
            }
        )
        trigger.continuation.finish()
        #expect(try await collection.value.deletedObjectCount == 0)
        try await store.verify(snapshot)
    }

    @Test("Separate store instances serialize capture and capacity retention")
    func concurrentCapacityRetention() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        let otherRepository = fixture.root.appending(path: "other")
        try FileManager.default.createDirectory(at: otherRepository, withIntermediateDirectories: true)
        let firstStore = SnapshotStore(
            storageURL: fixture.storage, maxConcurrentFileOperations: 1,
            cloneFilesWhenSupported: false, maximumStorageByteCount: 1_048_576
        )
        let secondStore = SnapshotStore(
            storageURL: fixture.storage, cloneFilesWhenSupported: false, maximumStorageByteCount: 1_048_576
        )
        let otherID = UUID()
        let otherFile = otherRepository.appending(path: "other.bin")
        try Data(repeating: 0x41, count: 800_000).write(to: otherFile)
        _ = try await secondStore.createSnapshot(repositoryURL: otherRepository, repositoryID: otherID, reason: .initial)
        try Data(repeating: 0x42, count: 800_000).write(to: otherFile)
        try fixture.write(String(repeating: "a", count: 2_000_000), path: "a.bin")
        try fixture.write(String(repeating: "b", count: 2_000_000), path: "b.bin")
        let trigger = AsyncStream<Void>.makeStream()
        let second = Task {
            for await _ in trigger.stream {
                return try await secondStore.createSnapshot(
                    repositoryURL: otherRepository, repositoryID: otherID, reason: .fileSystemEvent
                )
            }
            throw CancellationError()
        }
        let first = try await firstStore.createSnapshot(
            repositoryURL: fixture.repository, repositoryID: UUID(), reason: .fileSystemEvent,
            progress: { progress in
                if progress.filesProcessed == 1 { trigger.continuation.yield(()) }
            }
        )
        trigger.continuation.finish()
        let secondManifest = try await second.value
        try await firstStore.verify(first)
        try await secondStore.verify(secondManifest)
    }

    @Test("An active restore lease prevents deletion until it is released")
    func restoreLease() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("recoverable", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage)
        let id = UUID()
        let snapshot = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        let lease = try await store.acquireReadLease()
        let deletion = Task {
            try await store.deleteSnapshots(repositoryID: id, mode: .purgeUnreferencedObjects)
        }
        try await store.verify(snapshot)
        #expect(try await store.snapshotSummaries().count == 1)
        lease.release()
        #expect(try await deletion.value.deletedSnapshotCount == 1)
    }

    @Test("Independent file descriptions cannot enter the same operation lock")
    func fileLockExclusion() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appending(path: "operation.lock")
        let lease = try await FileOperationLock.acquire(at: url)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        lease.release()
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(descriptor, LOCK_UN) == 0)
    }

    @Test("Missing manifests fail both diagnostics and block GC and purge")
    func missingManifest() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("recoverable", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage)
        let id = UUID()
        let snapshot = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        let hash = try #require(snapshot.entries.first?.contentHash)
        let object = await store.objectURL(for: hash)
        try FileManager.default.removeItem(at: fixture.manifestURL(snapshot.id))
        #expect(try await !store.checkIntegrity(deep: false).isHealthy)
        #expect(try await !store.checkIntegrity(deep: true).isHealthy)
        await #expect(throws: DurepoError.self) { try await store.garbageCollect() }
        await #expect(throws: DurepoError.self) {
            try await store.deleteSnapshots(repositoryID: id, mode: .purgeUnreferencedObjects)
        }
        #expect(FileManager.default.fileExists(atPath: object.path))
        #expect(try await store.snapshotSummaries().count == 1)
    }

    @Test("Invalid manifest references stop GC before any object is removed")
    func invalidManifestReference() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("recoverable", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage)
        let snapshot = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: UUID(), reason: .manual)
        let broken = SnapshotManifest(
            id: snapshot.id, repositoryID: snapshot.repositoryID, repositoryName: "repo",
            reason: .manual, entries: [SnapshotEntry(relativePath: "file.txt", kind: .file, contentHash: "invalid", posixMode: 0o600)]
        )
        try JSONEncoder.durepo.encode(broken).write(to: fixture.manifestURL(snapshot.id))
        await #expect(throws: DurepoError.self) { try await store.garbageCollect() }
        try await store.verify(snapshot)
    }

    @Test("Integrity failures survive restart until a successful deep check")
    func persistentIntegrityFailure() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("good", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage)
        let id = UUID()
        let snapshot = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        let hash = try #require(snapshot.entries.first?.contentHash)
        try Data("evil".utf8).write(to: await store.objectURL(for: hash))
        #expect(try await !store.checkIntegrity(deep: true).isHealthy)
        let restarted = SnapshotStore(storageURL: fixture.storage)
        _ = try await restarted.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        try await restarted.verify(snapshot)
        await #expect(throws: DurepoError.self) { try await restarted.garbageCollect() }
        #expect(try await !restarted.checkIntegrity(deep: false).isHealthy)
        #expect(try await restarted.checkIntegrity(deep: true).isHealthy)
        #expect(try await restarted.garbageCollect().deletedObjectCount == 0)
    }

    @Test("Cancelling an operation waiting for a file lock does not leak the lock")
    func cancelledLockWait() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appending(path: "operation.lock")
        let first = try await FileOperationLock.acquire(at: url)
        let waiter = Task { try await FileOperationLock.acquire(at: url) }
        waiter.cancel()
        first.release()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        let next = try await FileOperationLock.acquire(at: url)
        next.release()
    }

    @Test("A corrupted CAS object is repaired from a healthy source", arguments: [true, false])
    func repairCorruptObject(cloning: Bool) async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("good", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage, cloneFilesWhenSupported: cloning)
        let id = UUID()
        let first = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        let hash = try #require(first.entries.first?.contentHash)
        try Data("evil".utf8).write(to: await store.objectURL(for: hash))
        let second = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        try await store.verify(first)
        try await store.verify(second)
        #expect(try await store.checkIntegrity().isHealthy)
    }

    @Test("An unreadable subtree cannot replace the last complete snapshot")
    func incompleteScan() async throws {
        let fixture = try SafetyFixture()
        let locked = fixture.repository.appending(path: "private")
        defer {
            _ = chmod(locked.path, 0o755)
            fixture.cleanup()
        }
        try fixture.write("important", path: "private/file.txt")
        let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 1)
        let id = UUID()
        let first = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .initial)
        #expect(chmod(locked.path, 0) == 0)
        await #expect(throws: (any Error).self) {
            try await store.createSnapshot(
                repositoryURL: fixture.repository, repositoryID: id, reason: .fileSystemEvent, detectAnomalies: true
            )
        }
        let summaries = try await store.snapshotSummaries()
        #expect(summaries.map(\.id) == [first.id])
        try await store.verify(first)
        await #expect(throws: (any Error).self) {
            try await store.restoreInPlace(
                snapshotID: first.id, repositoryURL: fixture.repository, repositoryID: id, exclusionRules: .defaults
            )
        }
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test("Uncommitted recovered manifests cannot prune the healthy predecessor")
    func interruptedSnapshotRecovery() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("ref: refs/heads/main\n", path: ".git/HEAD")
        let id = UUID()
        let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 1)
        let healthy = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .initial)
        let orphan = SnapshotManifest(
            repositoryID: id, repositoryName: "repo", createdAt: healthy.createdAt.addingTimeInterval(60),
            reason: .fileSystemEvent, entries: []
        )
        try JSONEncoder.durepo.encode(orphan).write(to: fixture.manifestURL(orphan.id))
        let restarted = SnapshotStore(storageURL: fixture.storage, retentionLimit: 1)
        let summaries = try await restarted.snapshotSummaries()
        #expect(summaries.count == 2)
        #expect(summaries.allSatisfy { $0.isProtected })
        #expect(summaries.first { $0.id == orphan.id }?.healthState == .anomalous)
        #expect(try await restarted.protectionAlerts().first?.kind == .snapshotRecovery)
        _ = try await restarted.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        #expect(try await restarted.snapshotSummaries().contains { $0.id == healthy.id })
        await #expect(throws: DurepoError.self) { try await restarted.garbageCollect() }
    }

    @Test("Committed deletions cannot be resurrected by a leftover manifest")
    func deletionTombstone() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("content", path: "file.txt")
        let store = SnapshotStore(storageURL: fixture.storage)
        let id = UUID()
        let snapshot = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .manual)
        let bytes = try Data(contentsOf: fixture.manifestURL(snapshot.id))
        _ = try await store.deleteSnapshots(repositoryID: id, mode: .keepObjects)
        try bytes.write(to: fixture.manifestURL(snapshot.id))
        let restarted = SnapshotStore(storageURL: fixture.storage)
        #expect(try await restarted.snapshotSummaries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL(snapshot.id).path))
    }

    @Test("In-place restore preserves excluded data and retains the original directory")
    func excludedRestoreData() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("old", path: "tracked.txt")
        let id = UUID()
        let rules = ExclusionRuleSet(["private/", ".env"])
        let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 1)
        let target = try await store.createSnapshot(
            repositoryURL: fixture.repository, repositoryID: id, reason: .initial, exclusionRules: rules
        )
        try fixture.write("current", path: "tracked.txt")
        try fixture.write("uncommitted private data", path: "private/notes.txt")
        try fixture.write("local configuration", path: ".env")
        let result = try await store.restoreInPlace(
            snapshotID: target.id, repositoryURL: fixture.repository, repositoryID: id, exclusionRules: rules
        )
        #expect(try fixture.read("tracked.txt") == "old")
        #expect(try fixture.read("private/notes.txt") == "uncommitted private data")
        #expect(try fixture.read(".env") == "local configuration")
        #expect(try String(contentsOf: result.rollbackURL.appending(path: "tracked.txt"), encoding: .utf8) == "current")
        #expect(try String(contentsOf: result.rollbackURL.appending(path: "private/notes.txt"), encoding: .utf8) == "uncommitted private data")
        #expect(try await store.snapshotSummaries().first { $0.id == result.preRestoreSnapshot.id }?.isProtected == true)
    }

    @Test("Excluded path conflicts abort in-place restore before exchanging directories")
    func excludedRestoreConflict() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("old file", path: "parent")
        let id = UUID()
        let store = SnapshotStore(storageURL: fixture.storage)
        let target = try await store.createSnapshot(repositoryURL: fixture.repository, repositoryID: id, reason: .initial)
        try FileManager.default.removeItem(at: fixture.repository.appending(path: "parent"))
        try fixture.write("private data", path: "parent/private.txt")
        await #expect(throws: DurepoError.self) {
            try await store.restoreInPlace(
                snapshotID: target.id, repositoryURL: fixture.repository, repositoryID: id,
                exclusionRules: ExclusionRuleSet(["parent/private.txt"])
            )
        }
        #expect(try fixture.read("parent/private.txt") == "private data")
    }

    @Test("Optimizer protects tracked content below a selected Git subdirectory")
    func optimizerSubdirectory() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("terraform {}", path: "nested/main.tf")
        try fixture.write("tracked source", path: "nested/.terraform/module/source.tf")
        try fixture.git(["init", "-q"])
        try fixture.git(["add", "."])
        let result = try await RepositoryExclusionOptimizer().optimize(
            repositoryURL: fixture.repository.appending(path: "nested"), including: []
        )
        #expect(result.rules.isEmpty)
        #expect(result.trackedSuggestionCount == 1)
        #expect(!result.gitTrackingVerificationFailed)
    }

    @Test("Optimizer protects tracked content in a linked worktree")
    func optimizerLinkedWorktree() async throws {
        let fixture = try SafetyFixture()
        defer { fixture.cleanup() }
        try fixture.write("terraform {}", path: "main.tf")
        try fixture.write("tracked source", path: ".terraform/module/source.tf")
        try fixture.git(["init", "-q"])
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=Durepo Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm",
            "fixture\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>",
        ])
        let worktree = fixture.root.appending(path: "worktree")
        try fixture.git(["worktree", "add", "-q", "--detach", worktree.path])
        let result = try await RepositoryExclusionOptimizer().optimize(repositoryURL: worktree, including: [])
        #expect(result.rules.isEmpty)
        #expect(result.trackedSuggestionCount == 1)
        #expect(!result.gitTrackingVerificationFailed)
    }
}

private struct SafetyFixture {
    let root: URL
    let repository: URL
    let storage: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DurepoSafety-\(UUID().uuidString)")
        repository = root.appending(path: "repository")
        storage = root.appending(path: "storage")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    }

    func write(_ contents: String, path: String) throws {
        let url = repository.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    func manifestURL(_ id: UUID) -> URL {
        storage.appending(path: "manifests/\(id.uuidString).json")
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
