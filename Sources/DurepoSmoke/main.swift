import DurepoCore
import Foundation

@main
struct DurepoSmoke {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "DurepoSmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        let storage = root.appending(path: "storage", directoryHint: .isDirectory)
        let restore = root.appending(path: "restored", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: repository.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/main\n".utf8).write(
            to: repository.appending(path: ".git/HEAD")
        )
        try Data("uncommitted work\n".utf8).write(
            to: repository.appending(path: "notes.txt")
        )
        try fileManager.createSymbolicLink(
            atPath: repository.appending(path: "latest").path,
            withDestinationPath: "notes.txt"
        )

        let store = SnapshotStore(storageURL: storage)
        let repositoryID = UUID()
        let initial = try await store.createSnapshot(
            repositoryURL: repository,
            repositoryID: repositoryID,
            reason: .smokeTest
        )
        try await store.verify(initial)

        _ = try await store.prepareMonitor(
            repositoryID: repositoryID,
            volumeID: "smoke-volume",
            rootID: "smoke-root"
        )
        _ = try await store.commitEvents(repositoryID: repositoryID, through: 0)
        try Data("agent update before deletion\n".utf8).write(
            to: repository.appending(path: "notes.txt")
        )
        try await store.recordEvent(
            repositoryID: repositoryID,
            eventID: 1,
            flags: 1,
            needsFullScan: false,
            changedPaths: ["notes.txt"]
        )
        let changes = try await store.pendingChangeSet(repositoryID: repositoryID, through: 1)
        let manifest = try await store.createSnapshot(
            repositoryURL: repository,
            repositoryID: repositoryID,
            reason: .fileSystemEvent,
            changeSet: changes
        )
        _ = try await store.commitEvents(repositoryID: repositoryID, through: 1)
        try await store.verify(manifest)

        try fileManager.removeItem(at: repository.appending(path: "notes.txt"))
        let restorer = SnapshotRestorer(store: store)
        _ = try await restorer.restore(manifest, to: restore)

        let restoredHead = try String(contentsOf: restore.appending(path: ".git/HEAD"), encoding: .utf8)
        let restoredNotes = try String(contentsOf: restore.appending(path: "notes.txt"), encoding: .utf8)
        guard restoredHead == "ref: refs/heads/main\n", restoredNotes == "agent update before deletion\n" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        print("Durepo smoke test passed")
        print("initial=\(initial.id.uuidString) recovery=\(manifest.id.uuidString) files=\(manifest.fileCount) bytes=\(manifest.logicalByteCount)")
    }
}
