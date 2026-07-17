import Darwin
import Foundation
import Testing
@testable import DurepoCore

@Suite("Snapshot store")
struct SnapshotStoreTests {
    @Test("Repository records remain compatible with pre-agent-bookmark data")
    func legacyRepositoryRecordDecoding() throws {
        let json = #"{"id":"3271F239-D6F3-474E-8C77-E9DAFC5EDF67","displayName":"m2horizon","bookmark":"AQID","addedAt":"2026-07-17T03:02:29Z","isEnabled":true}"#
        let record = try JSONDecoder.durepo.decode(
            RepositoryRecord.self,
            from: Data(json.utf8)
        )

        #expect(record.displayName == "m2horizon")
        #expect(record.bookmark == Data([1, 2, 3]))
        #expect(record.agentBookmark == nil)
        #expect(record.handoffBookmark == nil)
    }

    @Test("Snapshots and restores worktree, .git, and symlinks")
    func roundTrip() async throws {
        try await withFixture { fixture in
            try fixture.write("hello", to: "Sources/main.swift")
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            try FileManager.default.createSymbolicLink(
                atPath: fixture.repository.appending(path: "current").path,
                withDestinationPath: "Sources/main.swift"
            )

            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            #expect(manifest.entries.contains { $0.relativePath == ".git/HEAD" })
            #expect(manifest.entries.contains { $0.relativePath == "current" && $0.kind == .symbolicLink })
            try await store.verify(manifest)

            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "Sources/main.swift"), encoding: .utf8) == "hello")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.restore.appending(path: "current").path) == "Sources/main.swift")
        }
    }

    @Test("Content-addressed objects deduplicate identical files")
    func deduplication() async throws {
        try await withFixture { fixture in
            try fixture.write("same", to: "one.txt")
            try fixture.write("same", to: "two.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let hashes = manifest.entries.compactMap(\.contentHash)
            #expect(hashes.count == 2)
            #expect(Set(hashes).count == 1)
        }
    }

    @Test("Storage inside a repository is rejected")
    func rejectsRecursiveStorage() async throws {
        try await withFixture { fixture in
            let nestedStorage = fixture.repository.appending(path: "backup")
            let store = SnapshotStore(storageURL: nestedStorage)
            await #expect(throws: DurepoError.self) {
                try await store.createSnapshot(
                    repositoryURL: fixture.repository,
                    repositoryID: UUID(),
                    reason: .smokeTest
                )
            }
        }
    }

    @Test("Retention keeps only the newest snapshots")
    func retention() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage, retentionLimit: 3)
            for index in 0..<5 {
                try fixture.write("version \(index)", to: "file.txt")
                _ = try await store.createSnapshot(
                    repositoryURL: fixture.repository,
                    repositoryID: repositoryID,
                    reason: .manual
                )
            }
            let summaries = try await store.snapshotSummaries(repositoryID: repositoryID)
            #expect(summaries.count == 3)
            let manifestFiles = try FileManager.default.contentsOfDirectory(
                at: fixture.storage.appending(path: "manifests"),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            #expect(manifestFiles.count == 3)
        }
    }

    @Test("Deleting snapshots can retain content-addressed objects")
    func snapshotDeletionKeepsObjects() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("recoverable", to: "file.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .manual
            )
            let hash = try #require(manifest.entries.first { $0.relativePath == "file.txt" }?.contentHash)
            let object = await store.objectURL(for: hash)

            let result = try await store.deleteSnapshots(repositoryID: repositoryID, mode: .keepObjects)

            #expect(result == SnapshotDeletionResult(deletedSnapshotCount: 1, deletedObjectCount: 0))
            #expect(FileManager.default.fileExists(atPath: object.path))
            #expect(try await store.snapshotSummaries(repositoryID: repositoryID).isEmpty)
        }
    }

    @Test("Permanent deletion removes only objects unreferenced by retained snapshots")
    func permanentSnapshotDeletionPreservesSharedObjects() async throws {
        try await withFixture { fixture in
            let repositoryA = UUID()
            let repositoryB = UUID()
            try fixture.write("shared", to: "shared.txt")
            try fixture.write("only-a", to: "unique.txt")
            let secondRepository = fixture.root.appending(path: "repository-b", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: secondRepository, withIntermediateDirectories: true)
            try Data("shared".utf8).write(to: secondRepository.appending(path: "shared.txt"))

            let store = SnapshotStore(storageURL: fixture.storage)
            let manifestA = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryA,
                reason: .manual
            )
            let manifestB = try await store.createSnapshot(
                repositoryURL: secondRepository,
                repositoryID: repositoryB,
                reason: .manual
            )
            let sharedHash = try #require(manifestA.entries.first { $0.relativePath == "shared.txt" }?.contentHash)
            let uniqueHash = try #require(manifestA.entries.first { $0.relativePath == "unique.txt" }?.contentHash)
            #expect(manifestB.entries.first?.contentHash == sharedHash)

            let result = try await store.deleteSnapshots(
                repositoryID: repositoryA,
                mode: .purgeUnreferencedObjects
            )

            #expect(result == SnapshotDeletionResult(deletedSnapshotCount: 1, deletedObjectCount: 1))
            #expect(!FileManager.default.fileExists(atPath: await store.objectURL(for: uniqueHash).path))
            #expect(FileManager.default.fileExists(atPath: await store.objectURL(for: sharedHash).path))
            try await store.verify(manifestB)
            #expect(try await store.snapshotSummaries(repositoryID: repositoryA).isEmpty)
            #expect(try await store.snapshotSummaries(repositoryID: repositoryB).count == 1)
        }
    }

    @Test("Events arriving during a snapshot remain pending")
    func eventJournalCommitBoundary() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            var state = try await store.prepareMonitor(
                repositoryID: repositoryID,
                volumeID: "volume-a",
                rootID: "root-a"
            )
            #expect(state.hasPendingEvents)
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)

            try await store.recordEvent(repositoryID: repositoryID, eventID: 41, flags: 1, needsFullScan: false)
            let boundaryState = try await store.monitorState(repositoryID: repositoryID)
            let snapshotBoundary = try #require(boundaryState).lastSeenEventID
            try await store.recordEvent(repositoryID: repositoryID, eventID: 42, flags: 1, needsFullScan: true)
            state = try await store.commitEvents(repositoryID: repositoryID, through: snapshotBoundary)
            #expect(state.lastCommittedEventID == 41)
            #expect(state.lastSeenEventID == 42)
            #expect(state.hasPendingEvents)
            #expect(state.needsFullScan)
        }
    }

    @Test("Incremental snapshots reuse unchanged files and capture only dirty paths")
    func incrementalSnapshot() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("unchanged", to: "stable.txt")
            try fixture.write("before", to: "changed.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            let initial = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )
            let stableHash = try #require(initial.entries.first { $0.relativePath == "stable.txt" }?.contentHash)

            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            #expect(Darwin.chmod(fixture.repository.appending(path: "stable.txt").path, 0) == 0)
            try fixture.write("after", to: "changed.txt")
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 1,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["changed.txt"]
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 1)
            #expect(changes == SnapshotChangeSet(changedPaths: ["changed.txt"], needsFullScan: false))

            let incremental = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(incremental.entries.first { $0.relativePath == "stable.txt" }?.contentHash == stableHash)
            let changedHash = incremental.entries.first { $0.relativePath == "changed.txt" }?.contentHash
            #expect(changedHash != initial.entries.first { $0.relativePath == "changed.txt" }?.contentHash)
        }
    }

    @Test("Incremental directory deletion removes every descendant")
    func incrementalDirectoryDeletion() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            try fixture.write("one", to: "bulk/one.txt")
            try fixture.write("two", to: "bulk/nested/two.txt")
            try fixture.write("keep", to: "keep.txt")
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            _ = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .initial
            )

            try FileManager.default.removeItem(at: fixture.repository.appending(path: "bulk"))
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 2,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["bulk"]
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 2)
            let afterDeletion = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(!afterDeletion.entries.contains { $0.relativePath == "bulk" || $0.relativePath.hasPrefix("bulk/") })
            #expect(afterDeletion.entries.contains { $0.relativePath == "keep.txt" })
        }
    }

    @Test("Pending dirty paths survive a store restart")
    func dirtyPathPersistence() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 7,
                flags: 1,
                needsFullScan: false,
                changedPaths: ["Sources/main.swift", ".git/HEAD"]
            )

            let restarted = SnapshotStore(storageURL: fixture.storage)
            let changes = try await restarted.pendingChangeSet(repositoryID: repositoryID, through: 7)
            #expect(changes.changedPaths == [".git/HEAD", "Sources/main.swift"])
            #expect(!changes.needsFullScan)
        }
    }

    @Test("APFS-cloned objects survive source deletion")
    func cloneSurvivesSourceDeletion() async throws {
        try await withFixture { fixture in
            let contents = String(repeating: "0123456789abcdef", count: 65_536)
            try fixture.write(contents, to: "large.bin")
            let source = fixture.repository.appending(path: "large.bin")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let hash = try #require(manifest.entries.first { $0.relativePath == "large.bin" }?.contentHash)
            let object = await store.objectURL(for: hash)
            let sourceIdentifier = try source.resourceValues(forKeys: [.fileContentIdentifierKey]).fileContentIdentifier
            let objectIdentifier = try object.resourceValues(forKeys: [.fileContentIdentifierKey]).fileContentIdentifier
            #expect(String(describing: sourceIdentifier) == String(describing: objectIdentifier))

            try FileManager.default.removeItem(at: source)
            try await store.verify(manifest)
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "large.bin"), encoding: .utf8) == contents)
        }
    }

    @Test("Memory and streaming fallbacks preserve data without clone support")
    func copyFallbacks() async throws {
        try await withFixture { fixture in
            try fixture.write("small", to: "small.txt")
            try fixture.write(String(repeating: "large", count: 1_000), to: "large.txt")
            let store = SnapshotStore(
                storageURL: fixture.storage,
                maxConcurrentFileOperations: 4,
                smallFileThreshold: 16,
                cloneFilesWhenSupported: false
            )
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(try String(contentsOf: fixture.restore.appending(path: "small.txt"), encoding: .utf8) == "small")
            #expect(try String(contentsOf: fixture.restore.appending(path: "large.txt"), encoding: .utf8) == String(repeating: "large", count: 1_000))
        }
    }

    @Test("Agent health errors persist until cleared")
    func agentHealthPersistence() async throws {
        try await withFixture { fixture in
            let store = SnapshotStore(storageURL: fixture.storage)
            let repositoryID = UUID()
            let recorded = try await store.recordAgentError(repositoryID: repositoryID, message: "snapshot failed")
            let loaded = try #require(try await store.agentHealth())
            #expect(loaded.errorID == recorded.errorID)
            #expect(loaded.message == recorded.message)
            #expect(abs(loaded.updatedAt.timeIntervalSince(recorded.updatedAt)) < 0.001)
            try await store.clearAgentError(repositoryID: repositoryID)
            #expect(try await store.agentHealth() == nil)
        }
    }

    @Test("Generated dependency and build directories are excluded")
    func generatedDirectoriesAreExcluded() async throws {
        try await withFixture { fixture in
            try fixture.write("source", to: "Sources/main.swift")
            try fixture.write("dependency", to: "node_modules/package/index.js")
            try fixture.write("generated", to: "web/dist/app.js")
            try fixture.write("cache", to: ".venv/lib/cache.py")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            #expect(manifest.entries.contains { $0.relativePath == "Sources/main.swift" })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix("node_modules/") })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix("web/dist/") })
            #expect(!manifest.entries.contains { $0.relativePath.hasPrefix(".venv/") })
        }
    }

    @Test("Corrupt manifests are reported instead of silently hidden")
    func corruptManifestIsVisible() async throws {
        try await withFixture { fixture in
            let manifests = fixture.storage.appending(path: "manifests")
            try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
            let corrupt = manifests.appending(path: "\(UUID().uuidString).json")
            try Data("not-json".utf8).write(to: corrupt)
            let store = SnapshotStore(storageURL: fixture.storage)
            await #expect(throws: DurepoError.self) {
                try await store.prepare()
            }
        }
    }

    @Test("Stale temporary objects are removed on startup")
    func staleTemporaryCleanup() async throws {
        try await withFixture { fixture in
            let temporary = fixture.storage.appending(path: "temp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let stale = temporary.appending(path: "stale.object")
            try Data("partial".utf8).write(to: stale)
            let store = SnapshotStore(storageURL: fixture.storage, staleTemporaryAge: 0)
            try await store.prepare()
            #expect(!FileManager.default.fileExists(atPath: stale.path))
        }
    }

    @Test("Git lock files are not restored")
    func gitLocksAreExcludedFromRestore() async throws {
        try await withFixture { fixture in
            try fixture.write("ref: refs/heads/main\n", to: ".git/HEAD")
            try fixture.write("locked", to: ".git/index.lock")
            let store = SnapshotStore(storageURL: fixture.storage)
            let manifest = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            let restorer = SnapshotRestorer(store: store)
            _ = try await restorer.restore(manifest, to: fixture.restore)
            #expect(FileManager.default.fileExists(atPath: fixture.restore.appending(path: ".git/HEAD").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.restore.appending(path: ".git/index.lock").path))
        }
    }

    @Test("A ten-thousand-file deletion is captured incrementally")
    func tenThousandFileDeletion() async throws {
        try await withFixture { fixture in
            let repositoryID = UUID()
            let bulk = fixture.repository.appending(path: "bulk")
            try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
            for index in 0..<10_000 {
                let url = bulk.appending(path: "\(index).txt")
                #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
            }
            let store = SnapshotStore(storageURL: fixture.storage)
            _ = try await store.prepareMonitor(repositoryID: repositoryID, volumeID: "volume-a", rootID: "root-a")
            _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
            let initial = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: repositoryID,
                reason: .smokeTest
            )
            #expect(initial.fileCount == 10_000)
            let deletedPaths = (0..<10_000).map { "bulk/\($0).txt" }
            for path in deletedPaths {
                try FileManager.default.removeItem(at: fixture.repository.appending(path: path))
            }
            try await store.recordEvent(
                repositoryID: repositoryID,
                eventID: 10_000,
                flags: 1,
                needsFullScan: false,
                changedPaths: deletedPaths
            )
            let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 10_000)
            #expect(!changes.needsFullScan)
            let afterDeletion = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: initial.repositoryID,
                reason: .fileSystemEvent,
                changeSet: changes
            )
            #expect(afterDeletion.fileCount == 0)
        }
    }

    private func withFixture(
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await operation(fixture)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let repository: URL
    let storage: URL
    let restore: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DurepoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "repository", directoryHint: .isDirectory)
        storage = root.appending(path: "storage", directoryHint: .isDirectory)
        restore = root.appending(path: "restore", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let url = repository.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
