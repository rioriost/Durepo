import AppKit
import DurepoCore
import Foundation
import Observation
import ServiceManagement
import UserNotifications

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
    var snapshots: [SnapshotSummary] = []
    var protectionAlerts: [ProtectionAlert] = []
    var globalExclusionRules = ExclusionRuleSet.defaults.rules
    var selectedRepositoryID: UUID?
    var isBusy = false
    var progressDescription = ""
    var alert: AppAlert?
    var agentStatus = SMAppService.Status.notRegistered
    var loginItemStatus = SMAppService.Status.notRegistered
    var integrityReport: StoreIntegrityReport?

    private let storageURL: URL
    private let registry: RepositoryRegistry
    private let exclusionRuleStore: GlobalExclusionRuleStore
    private let exclusionOptimizer = RepositoryExclusionOptimizer()
    private let store: SnapshotStore
    private var pendingAgentHandoffURLs: [UUID: URL] = [:]
    private var presentedAgentErrorID: UUID?

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
        exclusionRuleStore = GlobalExclusionRuleStore(storageURL: resolvedStorage)
        store = SnapshotStore(storageURL: resolvedStorage)
        refreshServiceStatuses()
    }

    var storagePath: String { storageURL.path }

    var selectedRepository: RepositoryRecord? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var selectedSnapshots: [SnapshotSummary] {
        guard let selectedRepositoryID else { return snapshots }
        return snapshots.filter { $0.repositoryID == selectedRepositoryID }
    }

    func run() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await load()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3))
                let latestSnapshots = try await store.snapshotSummaries()
                if latestSnapshots != snapshots {
                    snapshots = latestSnapshots
                }
                let latestProtectionAlerts = try await store.protectionAlerts()
                if latestProtectionAlerts != protectionAlerts { protectionAlerts = latestProtectionAlerts }
                refreshServiceStatuses()
                try await refreshAgentHealth()
            } catch is CancellationError {
                return
            } catch {
                // A later refresh retries transient cross-process I/O failures.
            }
        }
    }

    func load() async {
        do {
            globalExclusionRules = try exclusionRuleStore.rules()
            var loadedRepositories = try await registry.records()
            loadedRepositories = try await prepareAgentHandoffs(for: loadedRepositories)
            repositories = loadedRepositories.sorted { $0.displayName < $1.displayName }
            snapshots = try await store.snapshotSummaries()
            protectionAlerts = try await store.protectionAlerts()
            if selectedRepositoryID == nil {
                selectedRepositoryID = repositories.first?.id
            }
            refreshServiceStatuses()
            try await refreshAgentHealth()
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
            let didAccess = url.startAccessingSecurityScopedResource()
            guard didAccess else { throw DurepoError.bookmarkAccessDenied }
            defer { url.stopAccessingSecurityScopedResource() }
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
            isBusy = true
            progressDescription = String(localized: "Optimizing exclusion rules…")
            let optimizedRules: [String]
            do {
                let optimization = try await exclusionOptimizer.optimize(
                    repositoryURL: url,
                    including: globalExclusionRules,
                    minimumConfidence: .high
                )
                optimizedRules = optimization.rules
            } catch {
                isBusy = false
                progressDescription = ""
                throw error
            }
            isBusy = false
            progressDescription = ""
            let record = RepositoryRecord(
                displayName: url.lastPathComponent,
                bookmark: bookmark,
                handoffBookmark: handoffBookmark,
                customExclusionRules: optimizedRules
            )
            try await registry.add(record)
            do {
                try await snapshot(record, reason: .initial)
                repositories.append(record)
                repositories.sort { $0.displayName < $1.displayName }
                selectedRepositoryID = record.id
                selection = .repositories
            } catch {
                try? await registry.remove(id: record.id)
                throw error
            }
        } catch {
            isBusy = false
            progressDescription = ""
            present(error)
        }
    }

    func remove(_ record: RepositoryRecord, deletionMode: SnapshotDeletionMode) async {
        isBusy = true
        progressDescription = String(localized: "Deleting snapshots…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            try await registry.remove(id: record.id)
            do {
                _ = try await store.deleteSnapshots(repositoryID: record.id, mode: deletionMode)
            } catch {
                try? await registry.add(record)
                throw error
            }
            repositories.removeAll { $0.id == record.id }
            snapshots.removeAll { $0.repositoryID == record.id }
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

    func createSnapshotsForAllRepositories() async {
        for repository in repositories where repository.isEnabled {
            do {
                try await snapshot(repository, reason: .manual)
            } catch {
                present(error)
                return
            }
        }
    }

    func runIntegrityCheck() async {
        isBusy = true
        progressDescription = String(localized: "Checking storage integrity…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            integrityReport = try await store.checkIntegrity()
        } catch {
            present(error)
        }
    }

    func garbageCollect() async {
        isBusy = true
        progressDescription = String(localized: "Reclaiming unreferenced data…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            _ = try await store.garbageCollect()
            integrityReport = try await store.checkIntegrity(deep: false)
        } catch {
            present(error)
        }
    }

    func exportDiagnostics() {
        guard let integrityReport else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Diagnostics")
        panel.nameFieldStringValue = "Durepo-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [JSONEncoder.OutputFormatting.prettyPrinted, .sortedKeys]
            try encoder.encode(integrityReport).write(to: url, options: Data.WritingOptions.atomic)
        } catch {
            present(error)
        }
    }

    func acknowledge(_ alert: ProtectionAlert) async {
        do {
            try await store.acknowledgeProtectionAlert(id: alert.id)
            protectionAlerts.removeAll { $0.id == alert.id }
        } catch {
            present(error)
        }
    }

    func setSnapshotProtected(_ summary: SnapshotSummary, isProtected: Bool) async {
        do {
            try await store.setSnapshotProtected(id: summary.id, isProtected: isProtected)
            if let index = snapshots.firstIndex(where: { $0.id == summary.id }) {
                let current = snapshots[index]
                snapshots[index] = SnapshotSummary(
                    id: current.id,
                    repositoryID: current.repositoryID,
                    repositoryName: current.repositoryName,
                    createdAt: current.createdAt,
                    reason: current.reason,
                    fileCount: current.fileCount,
                    logicalByteCount: current.logicalByteCount,
                    isProtected: isProtected,
                    healthState: current.healthState
                )
            }
        } catch {
            present(error)
        }
    }

    func repositoryName(for id: UUID) -> String {
        repositories.first(where: { $0.id == id })?.displayName ?? String(localized: "Unknown Repository")
    }

    func protectionAlertMessage(_ alert: ProtectionAlert) -> String {
        switch alert.kind {
        case .gitDirectoryDeleted:
            String(localized: "The .git directory disappeared. The last healthy snapshot is protected.")
        case .repositoryUnavailable:
            String(localized: "The protected repository is unavailable. The last healthy snapshot is protected.")
        case .massDeletion:
            String(localized: "A large number of files were deleted. The last healthy snapshot is protected.")
        case .fileCountDrop:
            String(localized: "The repository file count dropped sharply. The last healthy snapshot is protected.")
        case .massZeroByte:
            String(localized: "Many files were reduced to zero bytes. The last healthy snapshot is protected.")
        }
    }

    func exclusionRules(for record: RepositoryRecord) -> [String] {
        record.effectiveExclusionRules(globalRules: globalExclusionRules).rules
    }

    func updateGlobalExclusionRules(_ rules: [String]) {
        globalExclusionRules = rules
        do {
            try exclusionRuleStore.save(rules)
            let inheritingRepositoryIDs = repositories
                .filter { $0.customExclusionRules == nil }
                .map(\.id)
            Task { [weak self] in
                guard let self else { return }
                do {
                    for id in inheritingRepositoryIDs {
                        try await self.store.requireFullScan(repositoryID: id)
                    }
                } catch {
                    self.present(error)
                }
            }
        } catch {
            present(error)
        }
    }

    func saveExclusionRules(_ rules: [String], for record: RepositoryRecord) async -> Bool {
        var updated = record
        updated.customExclusionRules = ExclusionRuleSet(rules).rules
        do {
            try await registry.update(updated)
            if let index = repositories.firstIndex(where: { $0.id == updated.id }) {
                repositories[index] = updated
            }
            try await store.requireFullScan(repositoryID: updated.id)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func optimizedExclusionRules(
        for record: RepositoryRecord,
        existingRules: [String]
    ) async -> RepositoryExclusionOptimizationResult? {
        do {
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
            return try await exclusionOptimizer.optimize(
                repositoryURL: url,
                including: existingRules,
                minimumConfidence: .medium
            )
        } catch {
            present(error)
            return nil
        }
    }

    func restore(_ summary: SnapshotSummary) async {
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
            path: "\(summary.repositoryName)-Durepo-\(formatter.string(from: summary.createdAt))",
            directoryHint: .isDirectory
        )
        isBusy = true
        progressDescription = String(localized: "Verifying and restoring…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            let manifest = try await store.manifest(id: summary.id)
            let didAccess = parent.startAccessingSecurityScopedResource()
            defer { if didAccess { parent.stopAccessingSecurityScopedResource() } }
            let restorer = SnapshotRestorer(store: store)
            let restoredURL = try await restorer.restore(manifest, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([restoredURL])
        } catch {
            present(error)
        }
    }

    func snapshotDiff(_ summary: SnapshotSummary, offset: Int, limit: Int = 500) async -> SnapshotDiffPage? {
        do {
            return try await store.snapshotDiff(id: summary.id, offset: offset, limit: limit)
        } catch {
            present(error)
            return nil
        }
    }

    func snapshotEntries(_ summary: SnapshotSummary, offset: Int, limit: Int = 500) async -> SnapshotDiffPage? {
        do {
            return try await store.snapshotEntries(id: summary.id, offset: offset, limit: limit)
        } catch {
            present(error)
            return nil
        }
    }

    func restore(_ summary: SnapshotSummary, selecting paths: Set<String>) async {
        guard !paths.isEmpty else { return }
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
            path: "\(summary.repositoryName)-Durepo-Selection-\(formatter.string(from: summary.createdAt))",
            directoryHint: .isDirectory
        )
        isBusy = true
        progressDescription = String(localized: "Verifying and restoring selection…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
            let manifest = try await store.manifest(id: summary.id)
            let didAccess = parent.startAccessingSecurityScopedResource()
            defer { if didAccess { parent.stopAccessingSecurityScopedResource() } }
            let restorer = SnapshotRestorer(store: store)
            let restoredURL = try await restorer.restore(manifest, selecting: paths, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([restoredURL])
        } catch {
            present(error)
        }
    }

    func restoreInPlace(_ summary: SnapshotSummary) async {
        guard let record = repositories.first(where: { $0.id == summary.repositoryID }) else {
            present(DurepoError.repositoryNotRegistered)
            return
        }
        isBusy = true
        progressDescription = String(localized: "Creating a pre-restore snapshot…")
        defer {
            isBusy = false
            progressDescription = ""
        }
        do {
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
            let result = try await store.restoreInPlace(
                snapshotID: summary.id,
                repositoryURL: url,
                repositoryID: record.id,
                exclusionRules: record.effectiveExclusionRules(globalRules: globalExclusionRules),
                requiresRegisteredRepository: true
            )
            snapshots = try await store.snapshotSummaries()
            NSWorkspace.shared.activateFileViewerSelecting([result.restoredURL])
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
            exclusionRules: record.effectiveExclusionRules(globalRules: globalExclusionRules),
            requiresRegisteredRepository: true,
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
        snapshots.insert(SnapshotSummary(manifest: manifest), at: 0)
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

    private func refreshAgentHealth() async throws {
        guard let health = try await store.agentHealth(), health.errorID != presentedAgentErrorID else { return }
        presentedAgentErrorID = health.errorID
        alert = AppAlert(title: String(localized: "Background Protection Error"), message: health.message)
    }
}
