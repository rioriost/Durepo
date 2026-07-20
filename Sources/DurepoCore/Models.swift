import Foundation

public enum DurepoConstants {
    public static let appGroupIdentifier = "23889H77KX.st.rio.Durepo"
    public static let agentPlistName = "st.rio.Durepo.Agent.plist"
    public static let formatVersion = 1
    public static let defaultExcludedDirectoryNames: Set<String> = [
        ".build", ".cache", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".venv",
        "DerivedData", "__pycache__", "build", "coverage", "dist", "node_modules", "target", "venv",
    ]
}

public enum FileSystemEventPolicy {
    public static func ignoresOperationalNoise(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3 else { return false }
        for index in 0...(components.count - 3) where components[index] == ".git" {
            if components[index + 1] == "fsmonitor--daemon",
               components[index + 2] == "cookies" {
                return true
            }
        }
        return false
    }
}

public struct ExclusionRuleSet: Codable, Hashable, Sendable {
    public let rules: [String]
    private let parsedRules: [ParsedExclusionRule]

    public init(_ rules: some Sequence<String>) {
        self.rules = rules.compactMap(Self.normalizedRule)
        self.parsedRules = self.rules.compactMap(ParsedExclusionRule.init)
    }

    public static let defaults = ExclusionRuleSet(DurepoConstants.defaultExcludedDirectoryNames.sorted())

    public func excludes(_ relativePath: String, isDirectory: Bool = false) -> Bool {
        let path = Self.normalizedPath(relativePath)
        guard !path.isEmpty else { return false }
        let components = path.split(separator: "/").map(String.init)

        // Git metadata is a core recovery target and cannot be excluded.
        guard !components.contains(".git") else { return false }

        for componentIndex in components.indices {
            let candidate = components[...componentIndex].joined(separator: "/")
            let candidateIsDirectory = componentIndex < components.index(before: components.endIndex) || isDirectory
            var ignored = false
            for rule in parsedRules where rule.matches(candidate, isDirectory: candidateIsDirectory) {
                ignored = !rule.isNegated
            }
            if ignored { return true }
        }
        return false
    }

    public static func normalizedRule(_ rawRule: String) -> String? {
        var rule = rawRule.trimmingCharacters(in: .newlines)
        while rule.last == " " && !rule.hasSuffix("\\ ") { rule.removeLast() }
        guard !rule.isEmpty, rule != "!" else { return nil }
        return rule
    }

    private enum CodingKeys: String, CodingKey { case rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([String].self, forKey: .rules))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasPrefix("/") { result.removeFirst() }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

}

private struct ParsedExclusionRule: Hashable, Sendable {
    let pattern: String
    let isNegated: Bool
    let isDirectoryOnly: Bool
    let isAnchored: Bool
    let containsSlash: Bool

    init?(_ rawRule: String) {
        guard !rawRule.hasPrefix("#") else { return nil }
        var value = rawRule
        let escapedPrefix = value.hasPrefix("\\#") || value.hasPrefix("\\!")
        if escapedPrefix {
            value.removeFirst()
            isNegated = false
        } else if value.hasPrefix("!") {
            value.removeFirst()
            isNegated = true
        } else {
            isNegated = false
        }

        isDirectoryOnly = value.hasSuffix("/") && !value.hasSuffix("\\/")
        if isDirectoryOnly { value.removeLast() }
        isAnchored = value.hasPrefix("/")
        if isAnchored { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        pattern = value
        containsSlash = value.contains("/")
    }

    func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
        guard !isDirectoryOnly || isDirectory else { return false }
        let candidate = containsSlash || isAnchored
            ? relativePath
            : relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return Self.gitIgnoreGlob(pattern, matches: candidate)
    }

    private struct MatchPosition: Hashable {
        let pattern: Int
        let value: Int
    }

    private static func gitIgnoreGlob(_ patternString: String, matches valueString: String) -> Bool {
        let pattern = Array(patternString)
        let value = Array(valueString)
        var memo: [MatchPosition: Bool] = [:]

        func matches(_ patternIndex: Int, _ valueIndex: Int) -> Bool {
            let position = MatchPosition(pattern: patternIndex, value: valueIndex)
            if let cached = memo[position] { return cached }
            let result: Bool

            if patternIndex == pattern.count {
                result = valueIndex == value.count
            } else {
                switch pattern[patternIndex] {
                case "*":
                    var nextPatternIndex = patternIndex
                    while nextPatternIndex < pattern.count && pattern[nextPatternIndex] == "*" {
                        nextPatternIndex += 1
                    }
                    let isGlobstar = nextPatternIndex - patternIndex > 1
                    if isGlobstar {
                        let skipsFollowingSlash = nextPatternIndex < pattern.count && pattern[nextPatternIndex] == "/"
                        result = matches(nextPatternIndex, valueIndex)
                            || (skipsFollowingSlash && matches(nextPatternIndex + 1, valueIndex))
                            || (valueIndex < value.count && matches(patternIndex, valueIndex + 1))
                    } else {
                        result = matches(nextPatternIndex, valueIndex)
                            || (valueIndex < value.count && value[valueIndex] != "/"
                                && matches(patternIndex, valueIndex + 1))
                    }
                case "?":
                    result = valueIndex < value.count && value[valueIndex] != "/"
                        && matches(patternIndex + 1, valueIndex + 1)
                case "[":
                    if valueIndex < value.count,
                       value[valueIndex] != "/",
                       let characterClass = characterClass(in: pattern, from: patternIndex) {
                        result = characterClass.matches(value[valueIndex])
                            && matches(characterClass.nextPatternIndex, valueIndex + 1)
                    } else {
                        result = valueIndex < value.count && value[valueIndex] == "["
                            && matches(patternIndex + 1, valueIndex + 1)
                    }
                case "\\":
                    let literalIndex = patternIndex + 1
                    if literalIndex < pattern.count {
                        result = valueIndex < value.count && value[valueIndex] == pattern[literalIndex]
                            && matches(literalIndex + 1, valueIndex + 1)
                    } else {
                        result = valueIndex < value.count && value[valueIndex] == "\\"
                            && matches(patternIndex + 1, valueIndex + 1)
                    }
                default:
                    result = valueIndex < value.count && pattern[patternIndex] == value[valueIndex]
                        && matches(patternIndex + 1, valueIndex + 1)
                }
            }
            memo[position] = result
            return result
        }

        return matches(0, 0)
    }

    private struct CharacterClass {
        let characters: Set<Character>
        let ranges: [(Character, Character)]
        let isNegated: Bool
        let nextPatternIndex: Int

        func matches(_ character: Character) -> Bool {
            let scalar = character.unicodeScalars.first?.value
            let contained = characters.contains(character) || ranges.contains { lower, upper in
                guard let scalar,
                      let lower = lower.unicodeScalars.first?.value,
                      let upper = upper.unicodeScalars.first?.value else { return false }
                return lower <= scalar && scalar <= upper
            }
            return isNegated ? !contained : contained
        }
    }

    private static func characterClass(in pattern: [Character], from start: Int) -> CharacterClass? {
        var index = start + 1
        guard index < pattern.count else { return nil }
        var isNegated = false
        if pattern[index] == "!" || pattern[index] == "^" {
            isNegated = true
            index += 1
        }
        var characters: Set<Character> = []
        var ranges: [(Character, Character)] = []
        var previous: Character?
        while index < pattern.count, pattern[index] != "]" {
            let character = pattern[index]
            if character == "-", let lower = previous, index + 1 < pattern.count, pattern[index + 1] != "]" {
                ranges.append((lower, pattern[index + 1]))
                characters.remove(lower)
                previous = nil
                index += 2
                continue
            }
            characters.insert(character)
            previous = character
            index += 1
        }
        guard index < pattern.count, pattern[index] == "]" else { return nil }
        return CharacterClass(
            characters: characters,
            ranges: ranges,
            isNegated: isNegated,
            nextPatternIndex: index + 1
        )
    }
}

public struct RepositoryRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmark: Data
    public var agentBookmark: Data?
    public var handoffBookmark: Data?
    public var customExclusionRules: [String]?
    public var addedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data,
        agentBookmark: Data? = nil,
        handoffBookmark: Data? = nil,
        customExclusionRules: [String]? = nil,
        addedAt: Date = .now,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.agentBookmark = agentBookmark
        self.handoffBookmark = handoffBookmark
        self.customExclusionRules = customExclusionRules
        self.addedAt = addedAt
        self.isEnabled = isEnabled
    }

    public func effectiveExclusionRules(globalRules: [String]) -> ExclusionRuleSet {
        ExclusionRuleSet(customExclusionRules ?? globalRules)
    }
}

public enum SnapshotReason: String, Codable, Sendable {
    case initial
    case manual
    case fileSystemEvent
    case preRestore
    case smokeTest
}

public enum SnapshotHealthState: String, Codable, Sendable {
    case normal
    case anomalous
}

public enum RepositoryAnomalyKind: String, Codable, Sendable {
    case gitDirectoryDeleted
    case repositoryUnavailable
    case massDeletion
    case fileCountDrop
    case massZeroByte
}

public struct RepositoryAnomaly: Codable, Hashable, Sendable {
    public let kind: RepositoryAnomalyKind
    public let message: String
    public let removedFileCount: Int
    public let previousFileCount: Int

    public init(
        kind: RepositoryAnomalyKind,
        message: String,
        removedFileCount: Int = 0,
        previousFileCount: Int = 0
    ) {
        self.kind = kind
        self.message = message
        self.removedFileCount = removedFileCount
        self.previousFileCount = previousFileCount
    }
}

public struct ProtectionAlert: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let repositoryID: UUID
    public let snapshotID: UUID?
    public let protectedSnapshotID: UUID?
    public let kind: RepositoryAnomalyKind
    public let message: String
    public let createdAt: Date
    public let acknowledgedAt: Date?

    public init(
        id: UUID,
        repositoryID: UUID,
        snapshotID: UUID?,
        protectedSnapshotID: UUID?,
        kind: RepositoryAnomalyKind,
        message: String,
        createdAt: Date,
        acknowledgedAt: Date?
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.snapshotID = snapshotID
        self.protectedSnapshotID = protectedSnapshotID
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
    }
}

public enum SnapshotEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
}

public struct SnapshotExtendedAttribute: Codable, Hashable, Sendable {
    public let name: String
    public let value: Data

    public init(name: String, value: Data) {
        self.name = name
        self.value = value
    }
}

public struct SnapshotEntry: Codable, Hashable, Sendable {
    public let relativePath: String
    public let kind: SnapshotEntryKind
    public let contentHash: String?
    public let byteCount: Int64
    public let posixMode: UInt32
    public let modifiedAt: Date?
    public let symbolicLinkDestination: String?
    public let hardLinkGroup: String?
    public let allocatedByteCount: Int64?
    public let extendedAttributes: [SnapshotExtendedAttribute]?
    public let aclText: String?

    public init(
        relativePath: String,
        kind: SnapshotEntryKind,
        contentHash: String? = nil,
        byteCount: Int64 = 0,
        posixMode: UInt32,
        modifiedAt: Date? = nil,
        symbolicLinkDestination: String? = nil,
        hardLinkGroup: String? = nil,
        allocatedByteCount: Int64? = nil,
        extendedAttributes: [SnapshotExtendedAttribute]? = nil,
        aclText: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.posixMode = posixMode
        self.modifiedAt = modifiedAt
        self.symbolicLinkDestination = symbolicLinkDestination
        self.hardLinkGroup = hardLinkGroup
        self.allocatedByteCount = allocatedByteCount
        self.extendedAttributes = extendedAttributes
        self.aclText = aclText
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

public struct SnapshotSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let repositoryID: UUID
    public let repositoryName: String
    public let createdAt: Date
    public let reason: SnapshotReason
    public let fileCount: Int
    public let logicalByteCount: Int64
    public let isProtected: Bool
    public let healthState: SnapshotHealthState

    public init(manifest: SnapshotManifest) {
        id = manifest.id
        repositoryID = manifest.repositoryID
        repositoryName = manifest.repositoryName
        createdAt = manifest.createdAt
        reason = manifest.reason
        fileCount = manifest.fileCount
        logicalByteCount = manifest.logicalByteCount
        isProtected = false
        healthState = .normal
    }

    public init(
        id: UUID,
        repositoryID: UUID,
        repositoryName: String,
        createdAt: Date,
        reason: SnapshotReason,
        fileCount: Int,
        logicalByteCount: Int64,
        isProtected: Bool = false,
        healthState: SnapshotHealthState = .normal
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.createdAt = createdAt
        self.reason = reason
        self.fileCount = fileCount
        self.logicalByteCount = logicalByteCount
        self.isProtected = isProtected
        self.healthState = healthState
    }
}

public enum SnapshotDiffKind: String, Codable, Sendable {
    case added
    case modified
    case removed
    case unchanged
}

public struct SnapshotDiffEntry: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let kind: SnapshotDiffKind
    public let entryKind: SnapshotEntryKind
    public let byteCount: Int64

    public init(relativePath: String, kind: SnapshotDiffKind, entryKind: SnapshotEntryKind, byteCount: Int64) {
        self.relativePath = relativePath
        self.kind = kind
        self.entryKind = entryKind
        self.byteCount = byteCount
    }
}

public struct SnapshotDiffPage: Sendable {
    public let entries: [SnapshotDiffEntry]
    public let offset: Int
    public let hasMore: Bool

    public init(entries: [SnapshotDiffEntry], offset: Int, hasMore: Bool) {
        self.entries = entries
        self.offset = offset
        self.hasMore = hasMore
    }
}

public struct InPlaceRestoreResult: Sendable {
    public let restoredURL: URL
    public let preRestoreSnapshot: SnapshotManifest

    public init(restoredURL: URL, preRestoreSnapshot: SnapshotManifest) {
        self.restoredURL = restoredURL
        self.preRestoreSnapshot = preRestoreSnapshot
    }
}

public enum IntegrityIssueSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct IntegrityIssue: Codable, Hashable, Sendable {
    public let severity: IntegrityIssueSeverity
    public let message: String

    public init(severity: IntegrityIssueSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct StoreIntegrityReport: Codable, Sendable {
    public let checkedAt: Date
    public let snapshotCount: Int
    public let referencedObjectCount: Int
    public let storedObjectCount: Int
    public let orphanObjectCount: Int
    public let availableCapacity: Int64?
    public let issues: [IntegrityIssue]

    public var isHealthy: Bool { !issues.contains { $0.severity == .error } }

    public init(
        checkedAt: Date = .now,
        snapshotCount: Int,
        referencedObjectCount: Int,
        storedObjectCount: Int,
        orphanObjectCount: Int,
        availableCapacity: Int64?,
        issues: [IntegrityIssue]
    ) {
        self.checkedAt = checkedAt
        self.snapshotCount = snapshotCount
        self.referencedObjectCount = referencedObjectCount
        self.storedObjectCount = storedObjectCount
        self.orphanObjectCount = orphanObjectCount
        self.availableCapacity = availableCapacity
        self.issues = issues
    }
}

public struct GarbageCollectionResult: Sendable, Equatable {
    public let deletedObjectCount: Int
    public let reclaimedByteCount: Int64

    public init(deletedObjectCount: Int, reclaimedByteCount: Int64) {
        self.deletedObjectCount = deletedObjectCount
        self.reclaimedByteCount = reclaimedByteCount
    }
}

public enum SnapshotDeletionMode: Sendable, Equatable {
    /// Deletes snapshot metadata and manifests while retaining content-addressed objects.
    case keepObjects

    /// Also deletes objects referenced by the removed snapshots when no retained snapshot uses them.
    case purgeUnreferencedObjects
}

public struct SnapshotDeletionResult: Sendable, Equatable {
    public let deletedSnapshotCount: Int
    public let deletedObjectCount: Int

    public init(deletedSnapshotCount: Int, deletedObjectCount: Int) {
        self.deletedSnapshotCount = deletedSnapshotCount
        self.deletedObjectCount = deletedObjectCount
    }
}

public struct RepositoryMonitorState: Sendable {
    public let lastSeenEventID: UInt64
    public let lastCommittedEventID: UInt64
    public let hasPendingEvents: Bool
    public let needsFullScan: Bool
}

public struct AgentHealth: Sendable, Equatable {
    public let errorID: UUID
    public let message: String
    public let updatedAt: Date
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
    case corruptManifest(String)
    case repositoryNotRegistered
    case emptyRestoreSelection
    case garbageCollectionUnsafe
    case insufficientStorage(available: Int64, required: Int64)
    case gitOperationInProgress

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
        case .corruptManifest(let path): localized("Snapshot manifest is corrupted: %@", path)
        case .repositoryNotRegistered: localized("The repository is no longer registered for protection.")
        case .emptyRestoreSelection: localized("Select at least one file or directory to restore.")
        case .garbageCollectionUnsafe: localized("Garbage collection stopped because protection is active or metadata integrity could not be confirmed.")
        case .insufficientStorage(let available, let required):
            localized("Not enough storage is available. Available: %lld bytes; required: %lld bytes.", available, required)
        case .gitOperationInProgress:
            localized("Restore in place was stopped because a Git lock file indicates an operation may be in progress.")
        }
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .main, comment: "Durepo error")
        return String(format: format, locale: .current, arguments: arguments)
    }
}
