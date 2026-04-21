import SwiftUI
import CCRouterCore

@main
struct ModelBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("ModelBridge", systemImage: "arrow.triangle.branch") {
            ContentView(model: model)
                .frame(minWidth: 440, idealWidth: 456)
        }

        Settings {
            DoctorSettingsView(model: model)
                .frame(minWidth: 920, minHeight: 700)
        }
    }
}
