import Darwin
import Foundation

public actor SnapshotRestorer {
    private let store: SnapshotStore
    private let fileManager: FileManager

    public init(store: SnapshotStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public func restore(_ manifest: SnapshotManifest, to destination: URL) async throws -> URL {
        guard manifest.formatVersion == DurepoConstants.formatVersion else {
            throw DurepoError.unsupportedFormat(manifest.formatVersion)
        }
        let finalURL = destination.standardizedFileURL
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw DurepoError.destinationExists(finalURL.path)
        }
        try validate(manifest.entries)
        try await store.verify(manifest)

        let parent = finalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appending(path: ".durepo-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)

        do {
            let directories = manifest.entries
                .filter { $0.kind == .directory }
                .sorted { $0.relativePath.pathDepth < $1.relativePath.pathDepth }
            for entry in directories {
                let target = try targetURL(for: entry.relativePath, under: temporaryURL)
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }

            for entry in manifest.entries where entry.kind == .file && !entry.isGitLockFile {
                guard let hash = entry.contentHash else { throw DurepoError.missingObject(entry.relativePath) }
                let objectURL = await store.objectURL(for: hash)
                let target = try targetURL(for: entry.relativePath, under: temporaryURL)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: objectURL, to: target)
                try applyMetadata(entry, to: target)
            }

            for entry in manifest.entries where entry.kind == .symbolicLink {
                guard let linkDestination = entry.symbolicLinkDestination else {
                    throw DurepoError.unsafeManifestPath(entry.relativePath)
                }
                let target = try targetURL(for: entry.relativePath, under: temporaryURL)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkDestination)
            }

            for entry in directories.sorted(by: { $0.relativePath.pathDepth > $1.relativePath.pathDepth }) {
                try applyMetadata(entry, to: try targetURL(for: entry.relativePath, under: temporaryURL))
            }
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func validate(_ entries: [SnapshotEntry]) throws {
        let paths = Set(entries.map(\.relativePath))
        guard paths.count == entries.count else { throw DurepoError.unsafeManifestPath("duplicate path") }
        let linkPaths = entries.filter { $0.kind == .symbolicLink }.map(\.relativePath)
        for entry in entries {
            _ = try Self.validatedComponents(entry.relativePath)
            if linkPaths.contains(where: { entry.relativePath.hasPrefix($0 + "/") }) {
                throw DurepoError.unsafeManifestPath(entry.relativePath)
            }
        }
    }

    private func targetURL(for relativePath: String, under root: URL) throws -> URL {
        let components = try Self.validatedComponents(relativePath)
        return components.reduce(root) { result, component in
            result.appending(path: component)
        }
    }

    private static func validatedComponents(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.contains("\0") else {
            throw DurepoError.unsafeManifestPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DurepoError.unsafeManifestPath(path)
        }
        return components
    }

    private func applyMetadata(_ entry: SnapshotEntry, to url: URL) throws {
        guard Darwin.chmod(url.path, mode_t(entry.posixMode)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let modifiedAt = entry.modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }
}

private extension String {
    var pathDepth: Int { split(separator: "/").count }
}

private extension SnapshotEntry {
    var isGitLockFile: Bool {
        let components = relativePath.split(separator: "/")
        return components.contains(".git") && components.last?.hasSuffix(".lock") == true
    }
}
