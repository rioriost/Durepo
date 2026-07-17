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
    let optimize: ([String]) async -> [String]?
    let save: ([String]) async -> Void

    @State private var rules: [String]
    @State private var isOptimizing = false
    @State private var isSaving = false

    init(
        repository: RepositoryRecord,
        initialRules: [String],
        cancel: @escaping () -> Void,
        optimize: @escaping ([String]) async -> [String]?,
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
                        if let optimized = await optimize(rules) { rules = optimized }
                        isOptimizing = false
                    }
                }
            )
            .frame(minHeight: 260)

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
        .frame(width: 680, height: 500)
        .interactiveDismissDisabled()
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
            TableColumn("") { snapshot in
                Button("Restore…") { Task { await model.restore(snapshot) } }
                    .disabled(model.isBusy)
            }
            .width(90)
        }
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
            .frame(minHeight: 200)
        }
        .frame(minHeight: 390)
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
