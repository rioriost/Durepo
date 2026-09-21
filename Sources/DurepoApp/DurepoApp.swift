import AppKit
import SwiftUI

@main
struct DurepoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Durepo", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task { await model.run() }
                .alert(item: $model.alert) { alert in
                    if let recoveryURL = alert.recoveryURL {
                        return Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            primaryButton: .default(Text("Show Previous Folder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                            },
                            secondaryButton: .cancel(Text("OK"))
                        )
                    }
                    return Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Repository…") { Task { await model.addRepository() } }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.isBusy)
                Button("Snapshot All Now") { Task { await model.createSnapshotsForAllRepositories() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.repositories.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Link("Durepo Support", destination: URL(string: "https://github.com/rioriost/Durepo/issues")!)
                Link("Privacy Policy", destination: URL(string: "https://github.com/rioriost/Durepo/blob/main/PRIVACY.md")!)
            }
            CommandGroup(after: .sidebar) {
                Button("Dashboard") { model.selection = .dashboard }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Repositories") { model.selection = .repositories }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Snapshots") { model.selection = .snapshots }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 480)
        }


        MenuBarExtra("Durepo", systemImage: "externaldrive.badge.shield.half.filled") {
            DurepoMenuBarView(model: model)
        }
    }
}

private struct DurepoMenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Durepo") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Snapshot All Now") {
            Task { await model.createSnapshotsForAllRepositories() }
        }
        .disabled(model.isBusy || model.repositories.isEmpty)
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Durepo") { NSApp.terminate(nil) }
    }
}
