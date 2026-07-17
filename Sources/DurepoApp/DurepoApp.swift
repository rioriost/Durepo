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
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView(model: model)
                .frame(width: 460)
                .padding(20)
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
