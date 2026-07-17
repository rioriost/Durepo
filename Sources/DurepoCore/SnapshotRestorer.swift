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

            var hardLinkTargets: [String: (hash: String, url: URL)] = [:]
            for entry in manifest.entries where entry.kind == .file && !entry.isGitLockFile {
                guard let hash = entry.contentHash else { throw DurepoError.missingObject(entry.relativePath) }
                let objectURL = await store.objectURL(for: hash)
                let target = try targetURL(for: entry.relativePath, under: temporaryURL)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let group = entry.hardLinkGroup,
                   let existing = hardLinkTargets[group], existing.hash == hash {
                    guard Darwin.link(existing.url.path, target.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } else {
                    if Darwin.clonefile(objectURL.path, target.path, 0) != 0 {
                        let cloneError = errno
                        guard [EXDEV, ENOTSUP, EINVAL, EPERM, EACCES].contains(cloneError) else {
                            throw POSIXError(POSIXErrorCode(rawValue: cloneError) ?? .EIO)
                        }
                        let flags = copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)
                        guard Darwin.copyfile(objectURL.path, target.path, nil, flags) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                    if let group = entry.hardLinkGroup {
                        hardLinkTargets[group] = (hash, target)
                    }
                }
                // clonefile can propagate system-owned attributes that App Sandbox is
                // intentionally not permitted to remove. Strip everything removable;
                // FileMetadata tolerates the protected macOS attributes and never
                // records or reapplies them as repository metadata.
                try FileMetadata.removeExtendedAttributes(at: target)
                try FileMetadata.removeACL(at: target)
                try applyMetadata(entry, to: target)
            }

            for entry in manifest.entries where entry.kind == .symbolicLink {
                guard let linkDestination = entry.symbolicLinkDestination else {
                    throw DurepoError.unsafeManifestPath(entry.relativePath)
                }
                let target = try targetURL(for: entry.relativePath, under: temporaryURL)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkDestination)
                try FileMetadata.apply(entry, to: target, noFollow: true)
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

    public func restore(
        _ manifest: SnapshotManifest,
        selecting selectedPaths: Set<String>,
        to destination: URL
    ) async throws -> URL {
        guard !selectedPaths.isEmpty else { throw DurepoError.emptyRestoreSelection }
        let selectedEntries = try selection(from: manifest.entries, paths: selectedPaths)
        guard !selectedEntries.isEmpty else { throw DurepoError.emptyRestoreSelection }
        let filteredManifest = SnapshotManifest(
            repositoryID: manifest.repositoryID,
            repositoryName: manifest.repositoryName,
            createdAt: manifest.createdAt,
            reason: manifest.reason,
            entries: selectedEntries,
            warnings: manifest.warnings
        )
        return try await restore(filteredManifest, to: destination)
    }

    func replaceExistingDirectory(with manifest: SnapshotManifest, at repositoryURL: URL) async throws -> URL {
        let target = repositoryURL.standardizedFileURL
        var info = stat()
        guard lstat(target.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw DurepoError.invalidRepository(target.path)
        }

        let parent = target.deletingLastPathComponent()
        let staged = parent.appending(path: ".durepo-staged-\(UUID().uuidString)", directoryHint: .isDirectory)
        let rollback = parent.appending(path: ".durepo-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        _ = try await restore(manifest, to: staged)

        do {
            try fileManager.moveItem(at: target, to: rollback)
            do {
                try fileManager.moveItem(at: staged, to: target)
                try SnapshotStore.synchronizeDirectory(parent)
            } catch {
                try? fileManager.moveItem(at: rollback, to: target)
                try? fileManager.removeItem(at: staged)
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }

        try? fileManager.removeItem(at: rollback)
        try SnapshotStore.synchronizeDirectory(parent)
        return target
    }

    private func selection(from entries: [SnapshotEntry], paths: Set<String>) throws -> [SnapshotEntry] {
        for path in paths { _ = try Self.validatedComponents(path) }
        let includedPaths = Set(entries.compactMap { entry -> String? in
            paths.contains(where: { selected in
                entry.relativePath == selected || entry.relativePath.hasPrefix(selected + "/")
            }) ? entry.relativePath : nil
        })
        var requiredPaths = includedPaths
        for path in includedPaths {
            let components = path.split(separator: "/")
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requiredPaths.insert(components.prefix(count).joined(separator: "/"))
            }
        }
        return entries.filter { requiredPaths.contains($0.relativePath) }
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
        try FileMetadata.apply(entry, to: url)
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
