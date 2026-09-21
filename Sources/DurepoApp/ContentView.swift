import DurepoCore
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent")
                    .tag(AppSection.dashboard)
                Label("Repositories", systemImage: "externaldrive.badge.shield.half.filled")
                    .tag(AppSection.repositories)
                Label("Snapshots", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .tag(AppSection.snapshots)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Background protection", systemImage: model.isAgentEnabled ? "shield.lefthalf.filled" : "pause.circle")
                        .font(.caption.weight(.medium))
                    Text(model.isAgentEnabled ? "Enabled" : model.agentStatus == .requiresApproval ? "Approval Required" : "Disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Settings…") }
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } detail: {
            switch model.selection ?? .dashboard {
            case .dashboard:
                DashboardView(model: model)
            case .repositories:
                RepositoriesView(model: model)
            case .snapshots:
                SnapshotsView(model: model)
            }
        }
        .navigationTitle(sectionTitle)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.progressDescription)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(12)
                .background(.bar)
                .accessibilityElement(children: .combine)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.addRepository() }
                } label: {
                    Label("Add Repository", systemImage: "folder.badge.plus")
                }
                .help("Add Repository")
                .disabled(model.isBusy)
            }
        }
    }

    private var sectionTitle: LocalizedStringKey {
        switch model.selection ?? .dashboard {
        case .dashboard: "Dashboard"
        case .repositories: "Repositories"
        case .snapshots: "Snapshots"
        }
    }
}

private struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repository Protection")
                        .font(.title2.bold())
                    Text("Keep recovery points for your Git metadata and uncommitted work.")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.protectionAlerts) { alert in
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Destructive Change Detected")
                                    .font(.headline)
                                Text(model.repositoryName(for: alert.repositoryID))
                                    .font(.subheadline.bold())
                                Text(model.protectionAlertMessage(alert))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Acknowledge") {
                                Task { await model.acknowledge(alert) }
                            }
                            .disabled(model.isBusy)
                        }
                        .padding(6)
                    }
                }

                HStack(spacing: 16) {
                    MetricCard(title: "Repositories", value: "\(model.repositories.count)", symbol: "folder.badge.gearshape")
                    MetricCard(title: "Snapshots", value: "\(model.snapshots.count)", symbol: "clock.arrow.circlepath")
                }

                GroupBox("Recent snapshots") {
                    if model.snapshots.isEmpty {
                        ContentUnavailableView {
                            Label("No snapshots yet", systemImage: "clock.badge.questionmark")
                        } description: {
                            Text(model.repositories.isEmpty
                                 ? "Add a repository to create its first snapshot."
                                 : "Create a snapshot to save a recovery point.")
                        } actions: {
                            if model.repositories.isEmpty {
                                Button("Add Repository") { Task { await model.addRepository() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.isBusy)
                            } else {
                                Button("Snapshot All Now") { Task { await model.createSnapshotsForAllRepositories() } }
                                    .disabled(model.isBusy)
                            }
                        }
                    } else {
                        SnapshotTable(model: model, snapshots: Array(model.snapshots.prefix(8)))
                            .frame(minHeight: 220)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(value).font(.title2.bold())
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RepositoriesView: View {
    @Bindable var model: AppModel
    @State private var repositoryPendingDeletion: RepositoryRecord?
    @State private var repositoryEditingExclusions: RepositoryRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a repository to manage its recovery points and exclusion rules.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            if model.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No protected repositories", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Choose a repository or project folder. Durepo includes its .git directory and uncommitted files.")
                } actions: {
                    Button("Add Repository") { Task { await model.addRepository() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
            } else {
                List(selection: $model.selectedRepositoryID) {
                    ForEach(model.repositories) { repository in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(repository.displayName)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .help(repository.displayName)
                                Text(repository.customExclusionRules == nil
                                     ? String(localized: "Uses Default Rules")
                                     : String(localized: "Independent Exclusion Rules"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if let message = model.repositoryAccessErrors[repository.id] {
                                    Label(message, systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                } else if !repository.isEnabled {
                                    Label("Background protection is paused. Reconnect the repository folder.", systemImage: "pause.circle")
                                        .font(.callout)
                                }
                                HStack {
                                    if model.repositoryAccessErrors[repository.id] != nil || !repository.isEnabled {
                                        Button("Reconnect Folder…") {
                                            Task { await model.reconnectRepository(repository) }
                                        }
                                        .disabled(model.isBusy)
                                    } else {
                                        Button("Snapshot Now") {
                                            Task { await model.createSnapshot(of: repository) }
                                        }
                                        .disabled(model.isBusy)
                                    }
                                    Spacer()
                                    Text(repository.addedAt, format: .dateTime.year().month().day())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help("Added")
                                }
                            }
                            Menu {
                                Button("Edit Exclusion Rules") { repositoryEditingExclusions = repository }
                                Button("Show Snapshots") {
                                    model.selectedRepositoryID = repository.id
                                    model.selection = .snapshots
                                }
                                Divider()
                                Button("Remove Repository…", role: .destructive) { repositoryPendingDeletion = repository }
                            } label: {
                                Label("Repository Actions", systemImage: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .labelStyle(.iconOnly)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Repository Actions")
                            .accessibilityLabel(Text("Repository Actions"))
                            .accessibilityValue(repository.displayName)
                            .disabled(model.isBusy)
                        }
                        .padding(.vertical, 10)
                        .tag(repository.id)
                    }
                }
            }
        }

        .sheet(item: $repositoryPendingDeletion) { repository in
            RepositoryDeletionDialog(
                repository: repository,
                isBusy: model.isBusy,
                cancel: { repositoryPendingDeletion = nil },
                deleteSnapshots: {
                    repositoryPendingDeletion = nil
                    Task { await model.remove(repository, deletionMode: .keepObjects) }
                },
                permanentlyDeleteSnapshots: {
                    repositoryPendingDeletion = nil
                    Task { await model.remove(repository, deletionMode: .purgeUnreferencedObjects) }
                }
            )
        }
        .sheet(item: $repositoryEditingExclusions) { repository in
            RepositoryExclusionRulesDialog(
                repository: repository,
                initialRules: model.exclusionRules(for: repository),
                isBusy: model.isBusy,
                cancel: { repositoryEditingExclusions = nil },
                optimize: { rules in
                    await model.optimizedExclusionRules(for: repository, existingRules: rules)
                },
                save: { rules in
                    if await model.saveExclusionRules(rules, for: repository) {
                        repositoryEditingExclusions = nil
                    }
                }
            )
        }
    }
}

private struct RepositoryExclusionRulesDialog: View {
    let repository: RepositoryRecord
    let isBusy: Bool
    let cancel: () -> Void
    let optimize: ([String]) async -> RepositoryExclusionOptimizationResult?
    let save: ([String]?) async -> Void

    @State private var rules: [String]
    @State private var isOptimizing = false
    @State private var isSaving = false
    @State private var optimizationResult: RepositoryExclusionOptimizationResult?

    init(
        repository: RepositoryRecord,
        initialRules: [String],
        isBusy: Bool,
        cancel: @escaping () -> Void,
        optimize: @escaping ([String]) async -> RepositoryExclusionOptimizationResult?,
        save: @escaping ([String]?) async -> Void
    ) {
        self.repository = repository
        self.isBusy = isBusy
        self.cancel = cancel
        self.optimize = optimize
        self.save = save
        _rules = State(initialValue: initialRules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exclusion Rules")
                .font(.title2.bold())
            Text(repository.displayName)
                .font(.headline)
            Text(repository.customExclusionRules == nil
                 ? String(localized: "Uses Default Rules")
                 : String(localized: "Independent Exclusion Rules"))
                .font(.subheadline)
            Text("Saving creates independent rules. Use Default Rules to follow future default changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Uses .gitignore syntax. Git metadata is always protected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ExclusionRuleListEditor(
                rules: $rules,
                isOptimizing: isOptimizing,
                optimize: {
                    isOptimizing = true
                    Task {
                        if let result = await optimize(rules) {
                            rules = result.rules
                            optimizationResult = result
                        }
                        isOptimizing = false
                    }
                }
            )
            .frame(minHeight: 230)
            .disabled(isSaving || isOptimizing || isBusy)

            if let optimizationResult {
                ExclusionOptimizationSummary(result: optimizationResult)
            }

            Divider()

            HStack {
                Button("Cancel", action: cancel)
                    .disabled(isSaving)
                Button("Use Default Rules") {
                    isSaving = true
                    Task {
                        await save(nil)
                        isSaving = false
                    }
                }
                .disabled(isSaving || isOptimizing || isBusy)
                Spacer()
                Button("Save") {
                    isSaving = true
                    Task {
                        await save(rules)
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isOptimizing || isBusy)
            }
        }
        .padding(24)
        .frame(width: 680, height: 600)
        .interactiveDismissDisabled()
    }
}

private struct ExclusionOptimizationSummary: View {
    let result: RepositoryExclusionOptimizationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.suggestions.isEmpty {
                Text("No new exclusion rules were suggested.")
                    .font(.callout.weight(.medium))
            } else {
                Text(String(
                    format: String(localized: "%lld exclusion rules were suggested."),
                    Int64(result.suggestions.count)
                ))
                .font(.callout.weight(.medium))

                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(result.suggestions, id: \.self) { suggestion in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(suggestion.rule)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer(minLength: 8)
                                Text("\(suggestion.technology) • \(suggestion.evidence) • \(suggestion.confidence.localizedTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                .frame(maxHeight: 82)
            }

            if result.trackedSuggestionCount > 0 {
                Label(
                    String(
                        format: String(localized: "%lld suggestions were skipped because they match Git-tracked content."),
                        Int64(result.trackedSuggestionCount)
                    ),
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if result.gitTrackingVerificationFailed {
                Label(
                    "Git tracking information could not be verified, so no rules were added.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if result.scanWasLimited {
                Label(
                    "The repository scan reached its safety limit; suggestions may be incomplete.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension ExclusionSuggestionConfidence {
    var localizedTitle: String {
        switch self {
        case .high: String(localized: "High confidence")
        case .medium: String(localized: "Medium confidence")
        }
    }
}

private struct ExclusionRuleListEditor: View {
    @Binding var rules: [String]
    var isOptimizing = false
    var optimize: (() -> Void)?
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(rules.indices, id: \.self) { index in
                    TextField("Exclusion rule", text: ruleBinding(at: index))
                        .textFieldStyle(.plain)
                        .tag(index)
                }
            }
            .border(.separator)

            HStack(spacing: 8) {
                Button("Add") {
                    rules.append("")
                    selection = rules.indices.last
                }

                Button("Delete") {
                    guard let selection, rules.indices.contains(selection) else { return }
                    rules.remove(at: selection)
                    self.selection = rules.indices.contains(selection) ? selection : rules.indices.last
                }
                .disabled(selection == nil || !rules.indices.contains(selection ?? -1))

                Spacer()
                if let optimize {
                    Button("Optimize for Repository", action: optimize)
                        .disabled(isOptimizing)
                    if isOptimizing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func ruleBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { rules.indices.contains(index) ? rules[index] : "" },
            set: { if rules.indices.contains(index) { rules[index] = $0 } }
        )
    }
}

private struct RepositoryDeletionDialog: View {
    let repository: RepositoryRecord
    let isBusy: Bool
    let cancel: () -> Void
    let deleteSnapshots: () -> Void
    let permanentlyDeleteSnapshots: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remove Repository?")
                        .font(.title2.bold())
                    Text(repository.displayName)
                        .font(.headline)
                    Text("Background protection for this repository will stop. You can retain its deduplicated file data or permanently delete data that no other snapshot uses.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete Snapshots", action: deleteSnapshots)
                    .disabled(isBusy)
                Button("Permanently Delete Snapshots", role: .destructive, action: permanentlyDeleteSnapshots)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(width: 680)
        .interactiveDismissDisabled()
    }
}

private struct SnapshotsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Repository", selection: $model.selectedRepositoryID) {
                    Text("All Repositories").tag(UUID?.none)
                    ForEach(model.repositories) { repository in
                        Text(repository.displayName).tag(Optional(repository.id))
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            if model.selectedSnapshots.isEmpty {
                ContentUnavailableView {
                    Label("No snapshots", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("Create a snapshot to save a recovery point.")
                } actions: {
                    if let repository = model.selectedRepository {
                        Button("Snapshot Now") { Task { await model.createSnapshot(of: repository) } }
                            .disabled(model.isBusy || !repository.isEnabled)
                    } else if !model.repositories.isEmpty {
                        Button("Snapshot All Now") { Task { await model.createSnapshotsForAllRepositories() } }
                            .disabled(model.isBusy)
                    } else {
                        Button("Add Repository") { Task { await model.addRepository() } }
                            .disabled(model.isBusy)
                    }
                }
            } else {
                SnapshotTable(model: model, snapshots: model.selectedSnapshots)
            }
        }
    }
}

private struct SnapshotTable: View {
    @Bindable var model: AppModel
    let snapshots: [SnapshotSummary]
    @State private var snapshotShowingChanges: SnapshotSummary?
    @State private var snapshotRestoringInPlace: SnapshotSummary?

    var body: some View {
        Table(snapshots) {
            TableColumn("Repository") { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.repositoryName)
                        .lineLimit(1)
                        .help(snapshot.repositoryName)
                    if snapshot.healthState == .anomalous {
                        Label("Destructive change detected", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                    if snapshot.isProtected {
                        Label("Protected from retention", systemImage: "shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }
            .width(min: 140, ideal: 180)
            TableColumn("Created") { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.createdAt, format: .dateTime.year().month().day())
                    HStack(spacing: 6) {
                        Text(snapshot.createdAt, format: .dateTime.hour().minute().second())
                        Text(snapshot.reason.localizedTitle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 160)
            TableColumn("Contents") { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(snapshot.fileCount) files")
                    Text(ByteCountFormatter.string(fromByteCount: snapshot.logicalByteCount, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .width(min: 90, ideal: 100)
            TableColumn("Actions") { snapshot in
                HStack(spacing: 10) {
                    Button { snapshotShowingChanges = snapshot } label: {
                        Label("Changes…", systemImage: "list.bullet.rectangle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Changes…")
                    Menu {
                        Button(snapshot.isProtected ? "Remove Protection" : "Protect Snapshot") {
                            Task { await model.setSnapshotProtected(snapshot, isProtected: !snapshot.isProtected) }
                        }
                        Divider()
                        Button("Restore…") { Task { await model.restore(snapshot) } }
                        Button("Restore in Place…") { snapshotRestoringInPlace = snapshot }
                            .disabled(!model.repositories.contains { $0.id == snapshot.repositoryID })
                    } label: {
                        Label("Snapshot Actions", systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Snapshot Actions")
                    .accessibilityLabel(Text("Snapshot Actions"))
                }
                .disabled(model.isBusy)
            }
            .width(85)
        }

        .sheet(item: $snapshotShowingChanges) { snapshot in
            SnapshotChangesDialog(
                model: model,
                snapshot: snapshot,
                cancel: { snapshotShowingChanges = nil },
                restore: { paths in
                    snapshotShowingChanges = nil
                    Task { await model.restore(snapshot, selecting: paths) }
                }
            )
        }
        .sheet(item: $snapshotRestoringInPlace) { snapshot in
            InPlaceRestoreDialog(
                snapshot: snapshot,
                isBusy: model.isBusy,
                cancel: { snapshotRestoringInPlace = nil },
                restore: {
                    snapshotRestoringInPlace = nil
                    Task { await model.restoreInPlace(snapshot) }
                }
            )
        }
    }
}

private struct InPlaceRestoreDialog: View {
    let snapshot: SnapshotSummary
    let isBusy: Bool
    let cancel: () -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restore Repository in Place?")
                        .font(.title2.bold())
                    Text(snapshot.repositoryName)
                        .font(.headline)
                    Text("Durepo protects a pre-restore snapshot of included files and preserves currently excluded files. The restored and current folders are exchanged atomically. The previous folder is kept separately for recovery.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore in Place", role: .destructive, action: restore)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(width: 680)
        .interactiveDismissDisabled()
    }
}

private struct SnapshotChangesDialog: View {
    private enum ListingMode: String, CaseIterable, Identifiable {
        case changes
        case allFiles
        var id: Self { self }
    }

    @Bindable var model: AppModel
    let snapshot: SnapshotSummary
    let cancel: () -> Void
    let restore: (Set<String>) -> Void

    @State private var entries: [SnapshotDiffEntry] = []
    @State private var selection: Set<String> = []
    @State private var pageLoadState = SnapshotPageLoadState()
    @State private var hasMore = true
    @State private var listingMode = ListingMode.changes
    @State private var loadingError: String?
    private var isLoading: Bool { pageLoadState.isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Snapshot Changes")
                .font(.title2.bold())
            Text(snapshot.repositoryName)
                .font(.headline)
            Picker("Contents", selection: $listingMode) {
                Text("Changes").tag(ListingMode.changes)
                Text("All Files").tag(ListingMode.allFiles)
            }
            .pickerStyle(.segmented)
            Text(listingMode == .changes
                 ? "Select files or directories to restore. Removed items are shown for reference and cannot be restored from this snapshot."
                 : "Browse every item in this snapshot and select files or directories to restore.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(entries) { entry in
                HStack(spacing: 10) {
                    Toggle(entry.relativePath, isOn: selectionBinding(for: entry))
                        .labelsHidden()
                        .disabled(entry.kind == .removed)
                    Image(systemName: entry.entryKind == .directory ? "folder" : entry.entryKind == .symbolicLink ? "link" : "doc")
                        .foregroundStyle(.secondary)
                    Text(entry.kind.localizedTitle)
                        .font(.caption)
                        .foregroundStyle(entry.kind == .removed ? .red : .secondary)
                        .frame(width: 70, alignment: .leading)
                    Text(entry.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if entry.entryKind == .file {
                        Text(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if entries.isEmpty, let loadingError {
                    ContentUnavailableView(
                        "Unable to Load Snapshot",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadingError)
                    )
                } else if entries.isEmpty, !isLoading, !hasMore {
                    ContentUnavailableView("No changes", systemImage: "equal.circle")
                }
            }

            if hasMore {
                HStack {
                    Spacer()
                    Button(loadingError == nil ? String(localized: "Load More") : String(localized: "Retry")) {
                        Task { await loadNextPage() }
                    }
                        .disabled(isLoading)
                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }

            Divider()
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Select All") {
                    selection.formUnion(entries.lazy.filter { $0.kind != .removed }.map(\.relativePath))
                }
                .disabled(entries.allSatisfy { $0.kind == .removed })
                Spacer()
                Text(String(localized: "\(selection.count) selected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore Selected") { restore(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || isLoading || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 820, height: 600)
        .interactiveDismissDisabled()
        .task { await loadNextPage() }
        .onChange(of: listingMode) {
            pageLoadState.reset()
            entries = []
            selection = []
            hasMore = true
            loadingError = nil
            Task { await loadNextPage() }
        }
        .onDisappear { pageLoadState.reset() }
    }

    private func selectionBinding(for entry: SnapshotDiffEntry) -> Binding<Bool> {
        Binding(
            get: { selection.contains(entry.relativePath) },
            set: { selected in
                if selected { selection.insert(entry.relativePath) }
                else { selection.remove(entry.relativePath) }
            }
        )
    }

    private func loadNextPage() async {
        guard hasMore, let request = pageLoadState.begin() else { return }
        loadingError = nil
        let requestedMode = listingMode
        do {
            let page: SnapshotDiffPage
            if requestedMode == .changes {
                page = try await model.snapshotDiff(snapshot, offset: entries.count)
            } else {
                page = try await model.snapshotEntries(snapshot, offset: entries.count)
            }
            guard pageLoadState.finish(request), listingMode == requestedMode else { return }
            entries.append(contentsOf: page.entries)
            hasMore = page.hasMore
        } catch {
            guard pageLoadState.finish(request), listingMode == requestedMode else { return }
            loadingError = error.localizedDescription
            model.present(error)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            exclusionSettings
                .tabItem { Label("Exclusion Rules", systemImage: "line.3.horizontal.decrease") }
            diagnosticsSettings
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(minWidth: 520, minHeight: 440)
        .navigationTitle("Durepo Settings")
    }

    private var generalSettings: some View {
        Form {
            Section {
                Toggle("Background protection", isOn: Binding(
                    get: { model.isAgentEnabled },
                    set: { model.setAgentEnabled($0) }
                ))
                .disabled(model.isBusy)
                Text("The background agent only accesses folders you explicitly choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.agentStatus == .requiresApproval {
                    Label("Allow Durepo in System Settings > General > Login Items.", systemImage: "exclamationmark.circle")
                    Button("Login Item Settings") { SMAppService.openSystemSettingsLoginItems() }
                } else if model.agentStatus == .notFound {
                    Label("The embedded background agent could not be found.", systemImage: "exclamationmark.triangle")
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
                .disabled(model.isBusy)
            } header: {
                Text("General")
            }
            Section("Storage") {
                Text(model.storagePath)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Privacy") {
                Text("Durepo processes repository data locally and does not transmit file contents.")
                    .foregroundStyle(.secondary)
                Link("Privacy Policy", destination: URL(string: "https://github.com/rioriost/Durepo/blob/main/PRIVACY.md")!)
            }
        }
        .formStyle(.grouped)
    }

    private var exclusionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Exclusion Rules").font(.headline)
            Text("Uses .gitignore syntax. Repositories use these defaults unless independent rules are saved or automatically suggested. Use Default Rules in the repository editor to resume inheritance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ExclusionRuleListEditor(rules: Binding(
                get: { model.globalExclusionRules },
                set: { model.updateGlobalExclusionRules($0) }
            ))
            .disabled(model.isBusy)
        }
        .padding(20)
    }

    private var diagnosticsSettings: some View {
        Form {
            Section("Diagnostics") {
                if let report = model.integrityReport {
                    Label(
                        report.isHealthy ? "Storage is healthy" : "Storage needs attention",
                        systemImage: report.isHealthy ? "checkmark.shield" : "exclamationmark.shield"
                    )
                    Text(String(
                        format: String(localized: "%lld snapshots • %lld objects • %lld reclaimable"),
                        Int64(report.snapshotCount), Int64(report.storedObjectCount), Int64(report.orphanObjectCount)
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Check snapshot storage for missing or damaged data.")
                        .foregroundStyle(.secondary)
                }
                Button("Run Integrity Check") { Task { await model.runIntegrityCheck() } }
                Button("Export…") { model.exportDiagnostics() }
                    .disabled(model.integrityReport == nil)
            }
            Section("Storage Maintenance") {
                Text("Reclaim stored file data that is no longer used by any snapshot.")
                    .foregroundStyle(.secondary)
                Button("Reclaim Data") { Task { await model.garbageCollect() } }
                    .disabled(model.integrityReport?.orphanObjectCount == 0)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        .safeAreaInset(edge: .bottom) {
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.progressDescription).font(.callout)
                }
                .padding()
            }
        }
    }
}

private extension SnapshotReason {
    var localizedTitle: String {
        switch self {
        case .initial: String(localized: "Initial")
        case .manual: String(localized: "Manual")
        case .fileSystemEvent: String(localized: "File Change")
        case .preRestore: String(localized: "Before Restore")
        case .smokeTest: String(localized: "Smoke Test")
        }
    }
}

private extension SnapshotDiffKind {
    var localizedTitle: String {
        switch self {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .removed: String(localized: "Removed")
        case .unchanged: String(localized: "Existing")
        }
    }
}
