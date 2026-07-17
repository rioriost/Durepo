import Foundation

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
        var current = try records()
        current.removeAll { $0.id == record.id }
        current.append(record)
        try save(current)
    }

    public func remove(id: UUID) throws {
        var current = try records()
        current.removeAll { $0.id == id }
        try save(current)
    }

    public func update(_ record: RepositoryRecord) throws {
        var current = try records()
        guard let index = current.firstIndex(where: { $0.id == record.id }) else {
            current.append(record)
            try save(current)
            return
        }
        current[index] = record
        try save(current)
    }

    private func save(_ records: [RepositoryRecord]) throws {
        try fileManager.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(encoder.encode(records), to: registryURL, fileManager: fileManager)
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
