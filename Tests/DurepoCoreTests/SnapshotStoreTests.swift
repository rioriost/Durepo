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

    @Test("A ten-thousand-file deletion is captured by the next full snapshot")
    func tenThousandFileDeletion() async throws {
        try await withFixture { fixture in
            let bulk = fixture.repository.appending(path: "bulk")
            try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
            for index in 0..<10_000 {
                let url = bulk.appending(path: "\(index).txt")
                #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
            }
            let store = SnapshotStore(storageURL: fixture.storage)
            let initial = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: UUID(),
                reason: .smokeTest
            )
            #expect(initial.fileCount == 10_000)
            try FileManager.default.removeItem(at: bulk)
            let afterDeletion = try await store.createSnapshot(
                repositoryURL: fixture.repository,
                repositoryID: initial.repositoryID,
                reason: .fileSystemEvent
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
