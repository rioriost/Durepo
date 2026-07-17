import Foundation
import Testing
@testable import DurepoCore

@Suite("Snapshot store")
struct SnapshotStoreTests {
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
