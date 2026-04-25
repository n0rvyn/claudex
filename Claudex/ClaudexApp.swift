import SwiftUI
import CCRouterCore

@main
struct ClaudexApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("claudex.appearance") private var appearanceRaw: Int = 0

    private var preferredColorScheme: ColorScheme? {
        switch appearanceRaw {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        MenuBarExtra("Claudex", systemImage: "arrow.triangle.branch") {
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
