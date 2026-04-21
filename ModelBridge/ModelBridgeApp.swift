import SwiftUI
import CCRouterCore

@main
struct ModelBridgeApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("mb.appearance") private var appearanceRaw: Int = 0

    private var preferredColorScheme: ColorScheme? {
        switch appearanceRaw {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        MenuBarExtra("ModelBridge", systemImage: "arrow.triangle.branch") {
            ContentView(model: model)
                .preferredColorScheme(preferredColorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            DoctorSettingsView(model: model)
                .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
