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
    var recoveryURL: URL? = nil
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
    var repositoryAccessErrors: [UUID: String] = [:]

    private let storageURL: URL
    private let registry: RepositoryRegistry
    private let exclusionRuleStore: GlobalExclusionRuleStore
    private let exclusionOptimizer = RepositoryExclusionOptimizer()
    private let store: SnapshotStore
    private var pendingAgentHandoffURLs: [UUID: URL] = [:]
    private var presentedAgentErrorID: UUID?
    private var handoffCleanupTask: Task<Void, Never>?
    private var operationID: UUID?
    private var refreshErrorMessage: String?

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
                if !isBusy {
                    let loaded = try await registry.records()
                    if !isBusy {
                        applyRepositoryRecords(loaded)
                        await prepareAgentHandoffs(for: loaded)
                    }
                }
                refreshServiceStatuses()
                try await refreshAgentHealth()
                refreshErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                if refreshErrorMessage != error.localizedDescription {
                    refreshErrorMessage = error.localizedDescription
                    present(error)
                }
            }
        }
    }

    func load() async {
        var failures: [String] = []
        do {
            globalExclusionRules = try exclusionRuleStore.rules()
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            applyRepositoryRecords(try await registry.records())
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            snapshots = try await store.snapshotSummaries()
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            protectionAlerts = try await store.protectionAlerts()
        } catch {
            failures.append(error.localizedDescription)
        }
        refreshServiceStatuses()
        await prepareAgentHandoffs(for: repositories)
        do {
            try await refreshAgentHealth()
        } catch {
            failures.append(error.localizedDescription)
        }
        if !failures.isEmpty {
            alert = AppAlert(title: String(localized: "Durepo Error"), message: failures.joined(separator: "\n"))
        }
    }

    func addRepository() async {
        guard beginOperation(String(localized: "Optimizing exclusion rules…")) else { return }
        defer { endOperation() }
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
            var accessTransferred = false
            defer { if !accessTransferred { url.stopAccessingSecurityScopedResource() } }
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
            let optimization = try await exclusionOptimizer.optimize(
                repositoryURL: url,
                including: globalExclusionRules,
                minimumConfidence: .high
            )
            let record = RepositoryRecord(
                displayName: url.lastPathComponent,
                bookmark: bookmark,
                handoffBookmark: handoffBookmark,
                customExclusionRules: optimization.suggestions.isEmpty ? nil : optimization.rules
            )
            try await registry.add(record)
            repositories.append(record)
            repositories.sort { $0.displayName < $1.displayName }
            pendingAgentHandoffURLs[record.id] = url
            accessTransferred = true
            scheduleAgentHandoffCleanup()
            do {
                try await snapshot(record, reason: .initial)
            } catch {
                let snapshotError = error
                do {
                    try await registry.remove(id: record.id)
                    repositories.removeAll { $0.id == record.id }
                    pendingAgentHandoffURLs.removeValue(forKey: record.id)?.stopAccessingSecurityScopedResource()
                } catch {
                    repositoryAccessErrors[record.id] = error.localizedDescription
                    alert = AppAlert(
                        title: String(localized: "Durepo Error"),
                        message: "\(snapshotError.localizedDescription)\n\(error.localizedDescription)"
                    )
                    return
                }
                throw error
            }
            selectedRepositoryID = record.id
            selection = .repositories
            applyRepositoryRecords(try await registry.records())
        } catch {
            present(error)
        }
    }

    func remove(_ record: RepositoryRecord, deletionMode: SnapshotDeletionMode) async {
        guard beginOperation(String(localized: "Deleting snapshots…")) else { return }
        defer { endOperation() }
        do {
            let removedRecord = try await registry.remove(id: record.id)
            do {
                _ = try await store.deleteSnapshots(repositoryID: record.id, mode: deletionMode)
            } catch {
                let deletionError = error
                if let removedRecord {
                    do {
                        try await registry.add(removedRecord)
                    } catch {
                        alert = AppAlert(
                            title: String(localized: "Durepo Error"),
                            message: "\(deletionError.localizedDescription)\n\(error.localizedDescription)"
                        )
                        return
                    }
                }
                throw error
            }
            repositories.removeAll { $0.id == record.id }
            snapshots.removeAll { $0.repositoryID == record.id }
            repositoryAccessErrors.removeValue(forKey: record.id)
            pendingAgentHandoffURLs.removeValue(forKey: record.id)?.stopAccessingSecurityScopedResource()
            if selectedRepositoryID == record.id {
                selectedRepositoryID = repositories.first?.id
            }
        } catch {
            present(error)
        }
    }

    func createSnapshot(of record: RepositoryRecord) async {
        guard beginOperation(String(localized: "Preparing snapshot…")) else { return }
        defer { endOperation() }
        do {
            try await snapshot(record, reason: .manual)
        } catch {
            present(error)
        }
    }

    func createSnapshotsForAllRepositories() async {
        guard beginOperation(String(localized: "Preparing snapshot…")) else { return }
        defer { endOperation() }
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
        guard beginOperation(String(localized: "Checking storage integrity…")) else { return }
        defer { endOperation() }
        do {
            integrityReport = try await store.checkIntegrity()
        } catch {
            present(error)
        }
    }

    func garbageCollect() async {
        guard beginOperation(String(localized: "Reclaiming unreferenced data…")) else { return }
        defer { endOperation() }
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
        guard beginOperation("") else { return }
        defer { endOperation() }
        do {
            try await store.acknowledgeProtectionAlert(id: alert.id)
            protectionAlerts.removeAll { $0.id == alert.id }
        } catch {
            present(error)
        }
    }

    func setSnapshotProtected(_ summary: SnapshotSummary, isProtected: Bool) async {
        guard beginOperation("") else { return }
        defer { endOperation() }
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
        case .snapshotRecovery:
            String(localized: "A snapshot was recovered after an interrupted operation. Review it before acknowledging this alert.")
        }
    }

    func exclusionRules(for record: RepositoryRecord) -> [String] {
        record.effectiveExclusionRules(globalRules: globalExclusionRules).rules
    }

    func updateGlobalExclusionRules(_ rules: [String]) {
        guard !isBusy else { return }
        do {
            try exclusionRuleStore.save(rules)
            globalExclusionRules = rules
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

    func saveExclusionRules(_ rules: [String]?, for record: RepositoryRecord) async -> Bool {
        guard beginOperation("") else { return false }
        defer { endOperation() }
        do {
            let updated = try await registry.updateExclusionRules(id: record.id, rules: rules)
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
        guard beginOperation(String(localized: "Optimizing exclusion rules…")) else { return nil }
        defer { endOperation() }
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
        guard beginOperation(String(localized: "Verifying and restoring…")) else { return }
        defer { endOperation() }
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

    func snapshotDiff(_ summary: SnapshotSummary, offset: Int, limit: Int = 500) async throws -> SnapshotDiffPage {
        try await store.snapshotDiff(id: summary.id, offset: offset, limit: limit)
    }

    func snapshotEntries(_ summary: SnapshotSummary, offset: Int, limit: Int = 500) async throws -> SnapshotDiffPage {
        try await store.snapshotEntries(id: summary.id, offset: offset, limit: limit)
    }

    func restore(_ summary: SnapshotSummary, selecting paths: Set<String>) async {
        guard !paths.isEmpty else { return }
        guard beginOperation(String(localized: "Verifying and restoring selection…")) else { return }
        defer { endOperation() }
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
        guard beginOperation(String(localized: "Creating a pre-restore snapshot…")) else { return }
        defer { endOperation() }
        guard let record = repositories.first(where: { $0.id == summary.repositoryID }) else {
            present(DurepoError.repositoryNotRegistered)
            return
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
            var message = String(
                format: String(localized: "The repository was restored. The previous folder is kept at:\n%@\nKeep this folder until you have verified the restored repository."),
                result.rollbackURL.path
            )
            do {
                // Retain the selected URL's sandbox extension while rebinding the exchanged root.
                try await reconnectRestoredRepository(record, at: url)
            } catch {
                let accessMessage = String(
                    format: String(localized: "Background protection could not be reconnected to the restored folder: %@"),
                    error.localizedDescription
                )
                message += "\n\n" + accessMessage
                repositoryAccessErrors[record.id] = accessMessage
                do {
                    let paused = try await registry.setEnabled(id: record.id, isEnabled: false)
                    if let index = repositories.firstIndex(where: { $0.id == record.id }) {
                        repositories[index] = paused
                    }
                    _ = try await store.recordAgentError(repositoryID: record.id, message: accessMessage)
                } catch {
                    message += "\n\n" + error.localizedDescription
                }
            }
            do {
                snapshots = try await store.snapshotSummaries()
            } catch {
                message += "\n\n" + String(
                    format: String(localized: "The snapshot list could not be refreshed: %@"),
                    error.localizedDescription
                )
            }
            NSWorkspace.shared.activateFileViewerSelecting([result.restoredURL])
            alert = AppAlert(
                title: String(localized: "Restore Complete"),
                message: message,
                recoveryURL: result.rollbackURL
            )
        } catch {
            present(error)
        }
    }

    var isAgentEnabled: Bool {
        agentStatus == .enabled
    }

    func reconnectRepository(_ record: RepositoryRecord) async {
        guard beginOperation(String(localized: "Reconnecting repository…")) else { return }
        defer { endOperation() }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the repository folder to reconnect")
        panel.prompt = String(localized: "Reconnect")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await reconnectRestoredRepository(record, at: url, enableProtection: true)
            repositoryAccessErrors.removeValue(forKey: record.id)
        } catch {
            repositoryAccessErrors[record.id] = error.localizedDescription
            present(error)
        }
    }

    var launchesAtLogin: Bool {
        loginItemStatus == .enabled
    }

    func setAgentEnabled(_ isEnabled: Bool) {
        guard !isBusy else { return }
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
        guard !isBusy else { return }
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
        if stale {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let updated = try await registry.updateAppBookmark(id: record.id, bookmark: bookmark)
            if let index = repositories.firstIndex(where: { $0.id == record.id }) {
                repositories[index] = updated
            }
        }
        progressDescription = String(localized: "Preparing snapshot…")
        let currentOperation = operationID
        let manifest = try await store.createSnapshot(
            repositoryURL: url,
            repositoryID: record.id,
            reason: reason,
            exclusionRules: record.effectiveExclusionRules(globalRules: globalExclusionRules),
            requiresRegisteredRepository: true,
            progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.operationID == currentOperation else { return }
                    self.progressDescription = String(
                        format: String(localized: "%lld files • %@"),
                        Int64(progress.filesProcessed),
                        progress.currentPath
                    )
                }
            }
        )
        snapshots.insert(SnapshotSummary(manifest: manifest), at: 0)
    }

    private func prepareAgentHandoffs(for records: [RepositoryRecord]) async {
        for record in records where record.agentBookmark == nil && pendingAgentHandoffURLs[record.id] == nil {
            do {
                let updated = try await prepareAgentHandoff(for: record)
                if let index = repositories.firstIndex(where: { $0.id == record.id }) {
                    repositories[index] = updated
                }
                repositoryAccessErrors.removeValue(forKey: record.id)
            } catch {
                repositoryAccessErrors[record.id] = error.localizedDescription
            }
        }
        scheduleAgentHandoffCleanup()
    }

    private func prepareAgentHandoff(for record: RepositoryRecord) async throws -> RepositoryRecord {
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
        var accessTransferred = false
        defer { if !accessTransferred { url.stopAccessingSecurityScopedResource() } }
        if stale {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try await registry.updateAppBookmark(id: record.id, bookmark: bookmark)
        }
        let handoff = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let updated = try await registry.updateHandoffBookmark(id: record.id, bookmark: handoff)
        if updated.agentBookmark == nil {
            pendingAgentHandoffURLs.removeValue(forKey: record.id)?.stopAccessingSecurityScopedResource()
            pendingAgentHandoffURLs[record.id] = url
            accessTransferred = true
        }
        return updated
    }

    private func reconnectRestoredRepository(
        _ record: RepositoryRecord,
        at url: URL,
        enableProtection: Bool? = nil
    ) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw DurepoError.bookmarkAccessDenied
        }
        var accessTransferred = false
        defer { if !accessTransferred { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let handoff = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let updated = try await registry.replaceRepositoryAccess(
            id: record.id, bookmark: bookmark, handoffBookmark: handoff, isEnabled: enableProtection
        )
        pendingAgentHandoffURLs.removeValue(forKey: record.id)?.stopAccessingSecurityScopedResource()
        pendingAgentHandoffURLs[record.id] = url
        accessTransferred = true
        if let index = repositories.firstIndex(where: { $0.id == record.id }) {
            repositories[index] = updated
        }
        scheduleAgentHandoffCleanup()
        try await store.requireFullScan(repositoryID: record.id)
    }

    private func scheduleAgentHandoffCleanup() {
        guard !pendingAgentHandoffURLs.isEmpty, handoffCleanupTask == nil else { return }
        handoffCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.handoffCleanupTask = nil
                await self.releaseCompletedAgentHandoffs()
            } catch is CancellationError {
                self?.handoffCleanupTask = nil
            } catch {
                self?.handoffCleanupTask = nil
                self?.present(error)
            }
        }
    }

    private func releaseCompletedAgentHandoffs() async {
        do {
            let records = try await registry.records()
            let incompleteIDs = Set(records.filter { $0.agentBookmark == nil }.map(\.id))
            for id in pendingAgentHandoffURLs.keys where !incompleteIDs.contains(id) {
                pendingAgentHandoffURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
            }
            if !isBusy { applyRepositoryRecords(records) }
        } catch {
            present(error)
        }
        scheduleAgentHandoffCleanup()
    }

    private func applyRepositoryRecords(_ records: [RepositoryRecord]) {
        repositories = records.sorted { $0.displayName < $1.displayName }
        let registeredIDs = Set(records.map(\.id))
        let awaitingAccess = Set(records.filter { $0.agentBookmark == nil || !$0.isEnabled }.map(\.id))
        repositoryAccessErrors = repositoryAccessErrors.filter { awaitingAccess.contains($0.key) }
        if let selectedRepositoryID, !registeredIDs.contains(selectedRepositoryID) {
            self.selectedRepositoryID = nil
        }
    }

    private func beginOperation(_ description: String) -> Bool {
        guard !isBusy else { return false }
        operationID = UUID()
        isBusy = true
        progressDescription = description
        return true
    }

    private func endOperation() {
        operationID = nil
        isBusy = false
        progressDescription = ""
    }

    func present(_ error: Error) {
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
