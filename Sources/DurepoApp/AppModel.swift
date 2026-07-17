import AppKit
import DurepoCore
import Foundation
import Observation
import ServiceManagement

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum AppSection: Hashable {
    case dashboard
    case repositories
    case snapshots
}

@Observable
@MainActor
final class AppModel {
    var selection: AppSection? = .dashboard
    var repositories: [RepositoryRecord] = []
    var snapshots: [SnapshotManifest] = []
    var selectedRepositoryID: UUID?
    var isBusy = false
    var progressDescription = ""
    var alert: AppAlert?
    var agentStatus = SMAppService.Status.notRegistered
    var loginItemStatus = SMAppService.Status.notRegistered

    private let storageURL: URL
    private let registry: RepositoryRegistry
    private let store: SnapshotStore
    private var pendingAgentHandoffURLs: [UUID: URL] = [:]

    init() {
        let resolvedStorage: URL
        do {
            resolvedStorage = try DurepoEnvironment.defaultStorageURL()
        } catch {
            resolvedStorage = FileManager.default.temporaryDirectory
                .appending(path: "DurepoData", directoryHint: .isDirectory)
        }
        storageURL = resolvedStorage
        registry = RepositoryRegistry(storageURL: resolvedStorage)
        store = SnapshotStore(storageURL: resolvedStorage)
        refreshServiceStatuses()
    }

    var storagePath: String { storageURL.path }

    var selectedRepository: RepositoryRecord? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var selectedSnapshots: [SnapshotManifest] {
        guard let selectedRepositoryID else { return snapshots }
        return snapshots.filter { $0.repositoryID == selectedRepositoryID }
    }

    func run() async {
        await load()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3))
                let latestSnapshots = try await store.manifests()
                if latestSnapshots.map(\.id) != snapshots.map(\.id) {
                    snapshots = latestSnapshots
                }
                refreshServiceStatuses()
            } catch is CancellationError {
                return
            } catch {
                // A later refresh retries transient cross-process I/O failures.
            }
        }
    }

    func load() async {
        do {
            var loadedRepositories = try await registry.records()
            loadedRepositories = try await prepareAgentHandoffs(for: loadedRepositories)
            repositories = loadedRepositories.sorted { $0.displayName < $1.displayName }
            snapshots = try await store.manifests()
            if selectedRepositoryID == nil {
                selectedRepositoryID = repositories.first?.id
            }
            refreshServiceStatuses()
            scheduleAgentHandoffCleanup()
        } catch {
            present(error)
        }
    }

    func addRepository() async {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a repository to protect")
        panel.prompt = String(localized: "Protect")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let handoffBookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let record = RepositoryRecord(
                displayName: url.lastPathComponent,
                bookmark: bookmark,
                handoffBookmark: handoffBookmark
            )
            try await registry.add(record)
            repositories.append(record)
            repositories.sort { $0.displayName < $1.displayName }
            selectedRepositoryID = record.id
            selection = .repositories
            try await snapshot(record, reason: .initial)
        } catch {
            present(error)
        }
    }

    func remove(_ record: RepositoryRecord) async {
        do {
            try await registry.remove(id: record.id)
            repositories.removeAll { $0.id == record.id }
            if selectedRepositoryID == record.id {
                selectedRepositoryID = repositories.first?.id
            }
        } catch {
            present(error)
        }
    }

    func createSnapshot(of record: RepositoryRecord) async {
        do {
            try await snapshot(record, reason: .manual)
        } catch {
            present(error)
        }
    }

    func restore(_ manifest: SnapshotManifest) async {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a parent folder for the restore")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = parent.appending(
            path: "\(manifest.repositoryName)-Durepo-\(formatter.string(from: manifest.createdAt))",
            directoryHint: .isDirectory
        )
        isBusy = true
        progressDescription = String(localized: "Verifying and restoring…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            let didAccess = parent.startAccessingSecurityScopedResource()
            defer { if didAccess { parent.stopAccessingSecurityScopedResource() } }
            let restorer = SnapshotRestorer(store: store)
            let restoredURL = try await restorer.restore(manifest, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([restoredURL])
        } catch {
            present(error)
        }
    }

    var isAgentEnabled: Bool {
        agentStatus == .enabled
    }

    var launchesAtLogin: Bool {
        loginItemStatus == .enabled
    }

    func setAgentEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try agentService.register()
            } else {
                try agentService.unregister()
            }
            refreshServiceStatuses()
        } catch {
            present(error)
            refreshServiceStatuses()
        }
    }

    func setLaunchesAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try loginItemService.register()
            } else {
                try loginItemService.unregister()
            }
            refreshServiceStatuses()
        } catch {
            present(error)
            refreshServiceStatuses()
        }
    }

    func refreshServiceStatuses() {
        agentStatus = agentService.status
        loginItemStatus = loginItemService.status
    }

    private var agentService: SMAppService {
        .agent(plistName: DurepoConstants.agentPlistName)
    }

    private var loginItemService: SMAppService {
        .mainApp
    }

    private func snapshot(_ record: RepositoryRecord, reason: SnapshotReason) async throws {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw DurepoError.bookmarkAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        isBusy = true
        progressDescription = String(localized: "Preparing snapshot…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        let manifest = try await store.createSnapshot(
            repositoryURL: url,
            repositoryID: record.id,
            reason: reason,
            progress: { [weak self] progress in
                Task { @MainActor in
                    self?.progressDescription = String(
                        format: String(localized: "%lld files • %@"),
                        Int64(progress.filesProcessed),
                        progress.currentPath
                    )
                }
            }
        )
        snapshots.insert(manifest, at: 0)
    }

    private func prepareAgentHandoffs(for records: [RepositoryRecord]) async throws -> [RepositoryRecord] {
        var prepared = records
        for index in prepared.indices where prepared[index].agentBookmark == nil {
            var record = prepared[index]
            var stale = false
            let url = try URL(
                resolvingBookmarkData: record.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw DurepoError.bookmarkAccessDenied
            }
            do {
                record.handoffBookmark = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try await registry.update(record)
                pendingAgentHandoffURLs[record.id] = url
                prepared[index] = record
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
        }
        return prepared
    }

    private func scheduleAgentHandoffCleanup() {
        guard !pendingAgentHandoffURLs.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.releaseCompletedAgentHandoffs()
        }
    }

    private func releaseCompletedAgentHandoffs() async {
        guard let records = try? await registry.records() else {
            scheduleAgentHandoffCleanup()
            return
        }
        let completedIDs = Set(records.compactMap { $0.agentBookmark == nil ? nil : $0.id })
        for id in completedIDs {
            pendingAgentHandoffURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        }
        scheduleAgentHandoffCleanup()
    }

    private func present(_ error: Error) {
        alert = AppAlert(
            title: String(localized: "Durepo Error"),
            message: error.localizedDescription
        )
    }
}
