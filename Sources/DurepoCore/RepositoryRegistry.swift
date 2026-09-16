import Foundation

public enum RepositoryRegistryError: LocalizedError, Sendable {
    case accessChanged

    public var errorDescription: String? {
        String(localized: "Repository access changed during background setup. Please retry.")
    }
}

public actor RepositoryRegistry {
    private let registryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(storageURL: URL, fileManager: FileManager = .default) {
        self.registryURL = storageURL.appending(path: "repositories.json")
        self.fileManager = fileManager
        self.encoder = JSONEncoder.durepo
        self.decoder = JSONDecoder.durepo
    }

    public func records() throws -> [RepositoryRecord] {
        guard fileManager.fileExists(atPath: registryURL.path) else { return [] }
        return try decoder.decode([RepositoryRecord].self, from: Data(contentsOf: registryURL))
    }

    public func add(_ record: RepositoryRecord) throws {
        try mutate { current in
            guard !current.contains(where: { $0.id == record.id }) else {
                throw CocoaError(.fileWriteFileExists)
            }
            current.append(record)
        }
    }

    @discardableResult
    public func remove(id: UUID) throws -> RepositoryRecord? {
        try mutate { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
            return current.remove(at: index)
        }
    }

    public func update(_ record: RepositoryRecord) throws {
        try mutateRecord(id: record.id) { current in
            let agentBookmark = current.agentBookmark
            current = record
            if current.agentBookmark == nil {
                current.agentBookmark = agentBookmark
            }
            if current.agentBookmark != nil {
                current.handoffBookmark = nil
            }
        }
    }

    @discardableResult
    public func updateExclusionRules(id: UUID, rules: [String]?) throws -> RepositoryRecord {
        try mutateRecord(id: id) { $0.customExclusionRules = rules.map { ExclusionRuleSet($0).rules } }
    }

    @discardableResult
    public func updateAgentBookmark(
        id: UUID,
        bookmark: Data,
        matchingAppBookmark: Data? = nil
    ) throws -> RepositoryRecord {
        try mutateRecord(id: id) {
            if let matchingAppBookmark, $0.bookmark != matchingAppBookmark {
                throw RepositoryRegistryError.accessChanged
            }
            $0.agentBookmark = bookmark
            $0.handoffBookmark = nil
        }
    }

    @discardableResult
    public func replaceRepositoryAccess(
        id: UUID,
        bookmark: Data,
        handoffBookmark: Data,
        isEnabled: Bool? = nil
    ) throws -> RepositoryRecord {
        try mutateRecord(id: id) {
            $0.bookmark = bookmark
            $0.handoffBookmark = handoffBookmark
            $0.agentBookmark = nil
            if let isEnabled { $0.isEnabled = isEnabled }
        }
    }

    @discardableResult
    public func setEnabled(id: UUID, isEnabled: Bool) throws -> RepositoryRecord {
        try mutateRecord(id: id) { $0.isEnabled = isEnabled }
    }

    @discardableResult
    public func updateHandoffBookmark(id: UUID, bookmark: Data) throws -> RepositoryRecord {
        try mutateRecord(id: id) {
            if $0.agentBookmark == nil { $0.handoffBookmark = bookmark }
        }
    }

    @discardableResult
    public func updateAppBookmark(id: UUID, bookmark: Data) throws -> RepositoryRecord {
        try mutateRecord(id: id) { $0.bookmark = bookmark }
    }

    @discardableResult
    private func mutateRecord(
        id: UUID,
        _ mutation: (inout RepositoryRecord) throws -> Void
    ) throws -> RepositoryRecord {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw DurepoError.repositoryNotRegistered
            }
            try mutation(&records[index])
            return records[index]
        }
    }

    private func mutate<Result>(_ mutation: (inout [RepositoryRecord]) throws -> Result) throws -> Result {
        let directory = registryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try FileOperationLock.acquireSync(at: directory.appending(path: ".registry.lock"))
        defer { lock.release() }
        var current = try records()
        let result = try mutation(&current)
        try save(current)
        return result
    }

    private func save(_ records: [RepositoryRecord]) throws {
        try fileManager.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(encoder.encode(records), to: registryURL, fileManager: fileManager)
    }
}

public struct GlobalExclusionRuleStore {
    private struct Document: Codable {
        let formatVersion: Int
        let rules: [String]
    }

    private let settingsURL: URL
    private let fileManager: FileManager

    public init(storageURL: URL, fileManager: FileManager = .default) {
        settingsURL = storageURL.appending(path: "exclusion-rules.json")
        self.fileManager = fileManager
    }

    public func rules() throws -> [String] {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return ExclusionRuleSet.defaults.rules
        }
        let document = try JSONDecoder.durepo.decode(Document.self, from: Data(contentsOf: settingsURL))
        return ExclusionRuleSet(document.rules).rules
    }

    public func save(_ rules: [String]) throws {
        let document = Document(formatVersion: 1, rules: ExclusionRuleSet(rules).rules)
        try AtomicFileWriter.write(JSONEncoder.durepo.encode(document), to: settingsURL, fileManager: fileManager)
    }
}

extension JSONEncoder {
    static var durepo: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var durepo: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, fileManager: FileManager) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }
            try SnapshotStore.synchronizeDirectory(directory)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
