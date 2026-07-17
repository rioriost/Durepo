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
        let manifest = try await store.createSnapshot(
            repositoryURL: repository,
            repositoryID: repositoryID,
            reason: .smokeTest
        )
        try await store.verify(manifest)
        let restorer = SnapshotRestorer(store: store)
        _ = try await restorer.restore(manifest, to: restore)

        let restoredHead = try String(contentsOf: restore.appending(path: ".git/HEAD"), encoding: .utf8)
        let restoredNotes = try String(contentsOf: restore.appending(path: "notes.txt"), encoding: .utf8)
        guard restoredHead == "ref: refs/heads/main\n", restoredNotes == "uncommitted work\n" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        print("Durepo smoke test passed")
        print("snapshot=\(manifest.id.uuidString) files=\(manifest.fileCount) bytes=\(manifest.logicalByteCount)")
    }
}
