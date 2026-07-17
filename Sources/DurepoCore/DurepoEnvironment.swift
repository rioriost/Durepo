import Foundation

public enum DurepoEnvironment {
    public static func defaultStorageURL(fileManager: FileManager = .default) throws -> URL {
        if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: DurepoConstants.appGroupIdentifier
        ) {
            return groupURL.appending(path: "DurepoData", directoryHint: .isDirectory)
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "st.rio.Durepo", directoryHint: .isDirectory)
            .appending(path: "DurepoData", directoryHint: .isDirectory)
    }
}

public struct SecurityScopedRepository: ~Copyable {
    public let url: URL
    private let didStartAccessing: Bool

    public init(bookmark: Data) throws {
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw DurepoError.bookmarkAccessDenied
        }
        self.url = resolvedURL
        self.didStartAccessing = true
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
