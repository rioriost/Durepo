import CryptoKit
import Darwin
import Foundation

public actor SnapshotStore {
    public let storageURL: URL
    private let objectsURL: URL
    private let manifestsURL: URL
    private let temporaryURL: URL
    private let fileManager: FileManager
    private let excludedDirectoryNames: Set<String>

    public init(
        storageURL: URL,
        fileManager: FileManager = .default,
        excludedDirectoryNames: Set<String> = [".build", "DerivedData", "node_modules"]
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.objectsURL = storageURL.appending(path: "objects", directoryHint: .isDirectory)
        self.manifestsURL = storageURL.appending(path: "manifests", directoryHint: .isDirectory)
        self.temporaryURL = storageURL.appending(path: "temp", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.excludedDirectoryNames = excludedDirectoryNames
    }

    public func prepare() throws {
        for directory in [storageURL, objectsURL, manifestsURL, temporaryURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func createSnapshot(
        repositoryURL: URL,
        repositoryID: UUID,
        reason: SnapshotReason,
        progress: (@Sendable (SnapshotProgress) -> Void)? = nil
    ) throws -> SnapshotManifest {
        try prepare()

        let root = repositoryURL.resolvingSymlinksInPath().standardizedFileURL
        let storage = storageURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DurepoError.invalidRepository(root.path)
        }
        guard !storage.isDescendant(of: root) else { throw DurepoError.storageInsideRepository }
        guard !root.isDescendant(of: storage) else { throw DurepoError.repositoryInsideStorage }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        var enumerationWarnings: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                enumerationWarnings.append("\(url.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            throw DurepoError.invalidRepository(root.path)
        }

        var entries: [SnapshotEntry] = []
        var filesProcessed = 0
        var bytesProcessed: Int64 = 0

        for case let fileURL as URL in enumerator {
            let relativePath = try fileURL.safeRelativePath(from: root)
            let name = fileURL.lastPathComponent
            var info = try fileURL.lstatInfo()
            let fileType = info.st_mode & mode_t(S_IFMT)

            if fileType == mode_t(S_IFDIR), excludedDirectoryNames.contains(name), name != ".git" {
                enumerator.skipDescendants()
                continue
            }

            let mode = UInt32(info.st_mode & 0o7777)
            let modifiedAt = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )

            switch fileType {
            case mode_t(S_IFREG):
                let stored = try storeStableFile(at: fileURL)
                entries.append(
                    SnapshotEntry(
                        relativePath: relativePath,
                        kind: .file,
                        contentHash: stored.hash,
                        byteCount: stored.byteCount,
                        posixMode: mode,
                        modifiedAt: modifiedAt
                    )
                )
                filesProcessed += 1
                bytesProcessed += stored.byteCount
                progress?(SnapshotProgress(
                    filesProcessed: filesProcessed,
                    bytesProcessed: bytesProcessed,
                    currentPath: relativePath
                ))
            case mode_t(S_IFDIR):
                entries.append(
                    SnapshotEntry(
                        relativePath: relativePath,
                        kind: .directory,
                        posixMode: mode,
                        modifiedAt: modifiedAt
                    )
                )
            case mode_t(S_IFLNK):
                let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                entries.append(
                    SnapshotEntry(
                        relativePath: relativePath,
                        kind: .symbolicLink,
                        posixMode: mode,
                        modifiedAt: modifiedAt,
                        symbolicLinkDestination: destination
                    )
                )
            default:
                enumerationWarnings.append("Unsupported special file skipped: \(relativePath)")
            }
            info = stat()
        }

        let manifest = SnapshotManifest(
            repositoryID: repositoryID,
            repositoryName: root.lastPathComponent,
            reason: reason,
            entries: entries.sorted { $0.relativePath < $1.relativePath },
            warnings: enumerationWarnings
        )
        let manifestURL = manifestsURL.appending(path: "\(manifest.id.uuidString).json")
        try AtomicFileWriter.write(JSONEncoder.durepo.encode(manifest), to: manifestURL, fileManager: fileManager)
        return manifest
    }

    public func manifests(repositoryID: UUID? = nil) throws -> [SnapshotManifest] {
        try prepare()
        let urls = try fileManager.contentsOfDirectory(
            at: manifestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.durepo.decode(SnapshotManifest.self, from: Data(contentsOf: $0)) }
            .filter { repositoryID == nil || $0.repositoryID == repositoryID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func verify(_ manifest: SnapshotManifest) throws {
        guard manifest.formatVersion == DurepoConstants.formatVersion else {
            throw DurepoError.unsupportedFormat(manifest.formatVersion)
        }
        for entry in manifest.entries where entry.kind == .file {
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

    private func storeStableFile(at sourceURL: URL) throws -> (hash: String, byteCount: Int64) {
        for attempt in 0..<2 {
            let tempURL = temporaryURL.appending(path: "\(UUID().uuidString).object")
            do {
                let result = try Self.copyAndHashStableFile(from: sourceURL, to: tempURL, fileManager: fileManager)
                let destination = objectURL(for: result.hash)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: tempURL)
                } else {
                    do {
                        try fileManager.moveItem(at: tempURL, to: destination)
                    } catch {
                        if fileManager.fileExists(atPath: destination.path) {
                            try? fileManager.removeItem(at: tempURL)
                        } else {
                            throw error
                        }
                    }
                }
                return result
            } catch DurepoError.fileChangedDuringRead where attempt == 0 {
                try? fileManager.removeItem(at: tempURL)
                continue
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw error
            }
        }
        throw DurepoError.fileChangedDuringRead(sourceURL.path)
    }

    private static func copyAndHashStableFile(
        from sourceURL: URL,
        to temporaryURL: URL,
        fileManager: FileManager
    ) throws -> (hash: String, byteCount: Int64) {
        let descriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DurepoError.unsupportedFile(sourceURL.path)
        }
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

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
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              byteCount == Int64(after.st_size) else {
            throw DurepoError.fileChangedDuringRead(sourceURL.path)
        }
        return (hasher.finalize().hexString, byteCount)
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
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension URL {
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
