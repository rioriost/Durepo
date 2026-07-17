import SwiftUI

@main
struct DurepoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
    }
}
