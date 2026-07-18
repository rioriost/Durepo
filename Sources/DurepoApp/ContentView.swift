import DurepoCore
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
            .navigationTitle("Durepo")
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
        .toolbar {
            ToolbarItemGroup {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.progressDescription)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }
                Button {
                    Task { await model.addRepository() }
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .disabled(model.isBusy)
            }
        }
    }
}

private struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Dashboard")
                    .font(.largeTitle.bold())

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
                        }
                        .padding(6)
                    }
                }

                HStack(spacing: 16) {
                    MetricCard(title: "Protected repositories", value: "\(model.repositories.count)", symbol: "folder.badge.gearshape")
                    MetricCard(title: "Snapshots", value: "\(model.snapshots.count)", symbol: "clock.arrow.circlepath")
                }

                GroupBox("Recent snapshots") {
                    if model.snapshots.isEmpty {
                        ContentUnavailableView(
                            "No snapshots yet",
                            systemImage: "clock.badge.questionmark",
                            description: Text("Add a repository to create its first snapshot.")
                        )
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
            Text("Repositories").font(.largeTitle.bold())
            if model.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No protected repositories", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Choose a repository or project folder. Durepo includes its .git directory and uncommitted files.")
                } actions: {
                    Button("Add Repository") { Task { await model.addRepository() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $model.selectedRepositoryID) {
                    ForEach(model.repositories) { repository in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(repository.displayName).font(.headline)
                                Text(repository.addedAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit Exclusion Rules") {
                                repositoryEditingExclusions = repository
                            }
                            .disabled(model.isBusy)
                            Button("Snapshot Now") {
                                Task { await model.createSnapshot(of: repository) }
                            }
                            .disabled(model.isBusy)
                            Button(role: .destructive) {
                                repositoryPendingDeletion = repository
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Remove Repository…")
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 5)
                        .tag(repository.id)
                    }
                }
            }
        }
        .padding(24)
        .sheet(item: $repositoryPendingDeletion) { repository in
            RepositoryDeletionDialog(
                repository: repository,
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
    let cancel: () -> Void
    let optimize: ([String]) async -> RepositoryExclusionOptimizationResult?
    let save: ([String]) async -> Void

    @State private var rules: [String]
    @State private var isOptimizing = false
    @State private var isSaving = false
    @State private var optimizationResult: RepositoryExclusionOptimizationResult?

    init(
        repository: RepositoryRecord,
        initialRules: [String],
        cancel: @escaping () -> Void,
        optimize: @escaping ([String]) async -> RepositoryExclusionOptimizationResult?,
        save: @escaping ([String]) async -> Void
    ) {
        self.repository = repository
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

            if let optimizationResult {
                ExclusionOptimizationSummary(result: optimizationResult)
            }

            Divider()

            HStack {
                Button("Cancel", action: cancel)
                    .disabled(isSaving)
                Spacer()
                Button("Save") {
                    isSaving = true
                    Task {
                        await save(rules)
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isOptimizing)
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
        HStack(alignment: .top, spacing: 12) {
            List(selection: $selection) {
                ForEach(rules.indices, id: \.self) { index in
                    TextField("Exclusion rule", text: ruleBinding(at: index))
                        .textFieldStyle(.plain)
                        .tag(index)
                }
            }
            .border(.separator)

            VStack(alignment: .leading, spacing: 8) {
                Button("Add") {
                    rules.append("")
                    selection = rules.indices.last
                }
                .frame(maxWidth: .infinity)

                Button("Delete") {
                    guard let selection, rules.indices.contains(selection) else { return }
                    rules.remove(at: selection)
                    self.selection = rules.indices.contains(selection) ? selection : rules.indices.last
                }
                .frame(maxWidth: .infinity)
                .disabled(selection == nil)

                if let optimize {
                    Button("Optimize for Repository", action: optimize)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
                        .disabled(isOptimizing)
                    if isOptimizing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: 170)
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
                Button("Permanently Delete Snapshots", role: .destructive, action: permanentlyDeleteSnapshots)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
                Text("Snapshots").font(.largeTitle.bold())
                Spacer()
                Picker("Repository", selection: $model.selectedRepositoryID) {
                    Text("All Repositories").tag(UUID?.none)
                    ForEach(model.repositories) { repository in
                        Text(repository.displayName).tag(Optional(repository.id))
                    }
                }
                .frame(width: 240)
            }
            if model.selectedSnapshots.isEmpty {
                ContentUnavailableView("No snapshots", systemImage: "clock.badge.questionmark")
            } else {
                SnapshotTable(model: model, snapshots: model.selectedSnapshots)
            }
        }
        .padding(24)
    }
}

private struct SnapshotTable: View {
    @Bindable var model: AppModel
    let snapshots: [SnapshotSummary]
    @State private var snapshotShowingChanges: SnapshotSummary?
    @State private var snapshotRestoringInPlace: SnapshotSummary?

    var body: some View {
        Table(snapshots) {
            TableColumn("Repository") { snapshot in Text(snapshot.repositoryName) }
            TableColumn("Created") { snapshot in
                Text(snapshot.createdAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            TableColumn("Reason") { snapshot in Text(snapshot.reason.localizedTitle) }
            TableColumn("Files") { snapshot in Text("\(snapshot.fileCount)") }
            TableColumn("Size") { snapshot in
                Text(ByteCountFormatter.string(fromByteCount: snapshot.logicalByteCount, countStyle: .file))
            }
            TableColumn("Status") { snapshot in
                HStack(spacing: 5) {
                    if snapshot.isProtected {
                        Image(systemName: "shield.fill")
                            .foregroundStyle(.green)
                            .help("Protected from retention")
                    }
                    if snapshot.healthState == .anomalous {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Destructive change detected")
                    }
                }
            }
            .width(70)
            TableColumn("") { snapshot in
                HStack {
                    Button {
                        Task { await model.setSnapshotProtected(snapshot, isProtected: !snapshot.isProtected) }
                    } label: {
                        Image(systemName: snapshot.isProtected ? "shield.slash" : "shield")
                    }
                    .help(snapshot.isProtected ? "Remove Protection" : "Protect Snapshot")
                    Button { snapshotShowingChanges = snapshot } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                        .help("Changes…")
                        .disabled(model.isBusy)
                    Menu {
                        Button("Restore…") { Task { await model.restore(snapshot) } }
                        Button("Restore in Place…") { snapshotRestoringInPlace = snapshot }
                            .disabled(!model.repositories.contains { $0.id == snapshot.repositoryID })
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("Restore…")
                        .disabled(model.isBusy || !model.repositories.contains { $0.id == snapshot.repositoryID })
                }
            }
            .width(125)
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
                    Text("Durepo first creates a complete pre-restore snapshot, verifies the selected snapshot, and then replaces the repository. If replacement fails, the original directory is put back.")
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
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var listingMode = ListingMode.changes

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
                    Toggle("", isOn: selectionBinding(for: entry))
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
                if entries.isEmpty, !isLoading, !hasMore {
                    ContentUnavailableView("No changes", systemImage: "equal.circle")
                }
            }

            if hasMore {
                HStack {
                    Spacer()
                    Button("Load More") { Task { await loadNextPage() } }
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
                    .disabled(selection.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 820, height: 600)
        .interactiveDismissDisabled()
        .task { await loadNextPage() }
        .onChange(of: listingMode) {
            entries = []
            selection = []
            hasMore = true
            Task { await loadNextPage() }
        }
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
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = listingMode == .changes
            ? await model.snapshotDiff(snapshot, offset: entries.count)
            : await model.snapshotEntries(snapshot, offset: entries.count)
        guard let page else {
            hasMore = false
            return
        }
        entries.append(contentsOf: page.entries)
        hasMore = page.hasMore
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(
                "Background protection",
                isOn: Binding(
                    get: { model.isAgentEnabled },
                    set: { model.setAgentEnabled($0) }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                )
            )
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text("Launch at Login"))

            Divider()

            HStack {
                Text("Storage:")
                TextField("", text: .constant(model.storagePath))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
            }

            Divider()

            Text("Default Exclusion Rules")
                .font(.headline)
            Text("Uses .gitignore syntax. Repositories inherit these rules until repository-specific rules are saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExclusionRuleListEditor(
                rules: Binding(
                    get: { model.globalExclusionRules },
                    set: { model.updateGlobalExclusionRules($0) }
                )
            )
            .frame(height: 180)
            .padding(.bottom, 16)

            Divider()

            Text("Diagnostics")
                .font(.headline)
            if let report = model.integrityReport {
                Label(
                    report.isHealthy ? "Storage is healthy" : "Storage needs attention",
                    systemImage: report.isHealthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .foregroundStyle(report.isHealthy ? .green : .red)
                Text(String(
                    format: String(localized: "%lld snapshots • %lld objects • %lld reclaimable"),
                    Int64(report.snapshotCount),
                    Int64(report.storedObjectCount),
                    Int64(report.orphanObjectCount)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Run Integrity Check") { Task { await model.runIntegrityCheck() } }
                Button("Reclaim Data") { Task { await model.garbageCollect() } }
                    .disabled(model.integrityReport?.orphanObjectCount == 0)
                Button("Export…") { model.exportDiagnostics() }
                    .disabled(model.integrityReport == nil)
            }
            .disabled(model.isBusy)
        }
        .frame(minHeight: 500)
        .navigationTitle("Durepo Settings")
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
