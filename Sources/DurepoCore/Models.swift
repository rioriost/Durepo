import Foundation

public enum DurepoConstants {
    public static let appGroupIdentifier = "23889H77KX.st.rio.Durepo"
    public static let agentPlistName = "st.rio.Durepo.Agent.plist"
    public static let formatVersion = 1
}

public struct RepositoryRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmark: Data
    public var agentBookmark: Data?
    public var handoffBookmark: Data?
    public var addedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data,
        agentBookmark: Data? = nil,
        handoffBookmark: Data? = nil,
        addedAt: Date = .now,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.agentBookmark = agentBookmark
        self.handoffBookmark = handoffBookmark
        self.addedAt = addedAt
        self.isEnabled = isEnabled
    }
}

public enum SnapshotReason: String, Codable, Sendable {
    case initial
    case manual
    case fileSystemEvent
    case preRestore
    case smokeTest
}

public enum SnapshotEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
}

public struct SnapshotEntry: Codable, Hashable, Sendable {
    public let relativePath: String
    public let kind: SnapshotEntryKind
    public let contentHash: String?
    public let byteCount: Int64
    public let posixMode: UInt32
    public let modifiedAt: Date?
    public let symbolicLinkDestination: String?

    public init(
        relativePath: String,
        kind: SnapshotEntryKind,
        contentHash: String? = nil,
        byteCount: Int64 = 0,
        posixMode: UInt32,
        modifiedAt: Date? = nil,
        symbolicLinkDestination: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.posixMode = posixMode
        self.modifiedAt = modifiedAt
        self.symbolicLinkDestination = symbolicLinkDestination
    }
}

public struct SnapshotManifest: Codable, Identifiable, Sendable {
    public let formatVersion: Int
    public let id: UUID
    public let repositoryID: UUID
    public let repositoryName: String
    public let createdAt: Date
    public let reason: SnapshotReason
    public let entries: [SnapshotEntry]
    public let warnings: [String]

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        repositoryName: String,
        createdAt: Date = .now,
        reason: SnapshotReason,
        entries: [SnapshotEntry],
        warnings: [String] = []
    ) {
        self.formatVersion = DurepoConstants.formatVersion
        self.id = id
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.createdAt = createdAt
        self.reason = reason
        self.entries = entries
        self.warnings = warnings
    }

    public var fileCount: Int {
        entries.lazy.filter { $0.kind == .file }.count
    }

    public var logicalByteCount: Int64 {
        entries.reduce(0) { $0 + $1.byteCount }
    }
}

public struct SnapshotProgress: Sendable {
    public let filesProcessed: Int
    public let bytesProcessed: Int64
    public let currentPath: String

    public init(filesProcessed: Int, bytesProcessed: Int64, currentPath: String) {
        self.filesProcessed = filesProcessed
        self.bytesProcessed = bytesProcessed
        self.currentPath = currentPath
    }
}

public enum DurepoError: Error, LocalizedError, Sendable {
    case invalidRepository(String)
    case storageInsideRepository
    case repositoryInsideStorage
    case unsupportedFile(String)
    case fileChangedDuringRead(String)
    case unsafeManifestPath(String)
    case missingObject(String)
    case destinationExists(String)
    case bookmarkAccessDenied
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let path): localized("Invalid repository: %@", path)
        case .storageInsideRepository: localized("Backup storage must not be inside the protected repository.")
        case .repositoryInsideStorage: localized("A repository inside Durepo storage cannot be protected.")
        case .unsupportedFile(let path): localized("Unsupported file type: %@", path)
        case .fileChangedDuringRead(let path): localized("File changed while it was being copied: %@", path)
        case .unsafeManifestPath(let path): localized("Unsafe path in snapshot manifest: %@", path)
        case .missingObject(let hash): localized("Snapshot object is missing: %@", hash)
        case .destinationExists(let path): localized("Restore destination already exists: %@", path)
        case .bookmarkAccessDenied: localized("Access to the selected folder was denied.")
        case .unsupportedFormat(let version): localized("Unsupported snapshot format: %lld", Int64(version))
        }
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .main, comment: "Durepo error")
        return String(format: format, locale: .current, arguments: arguments)
    }
}
