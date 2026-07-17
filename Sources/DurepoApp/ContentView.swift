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
                            Button("Snapshot Now") {
                                Task { await model.createSnapshot(of: repository) }
                            }
                            .disabled(model.isBusy)
                            Button(role: .destructive) {
                                Task { await model.remove(repository) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 5)
                        .tag(repository.id)
                    }
                }
            }
        }
        .padding(24)
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
    let snapshots: [SnapshotManifest]

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
        }
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
