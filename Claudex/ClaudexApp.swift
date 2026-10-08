import SwiftUI
import CCRouterCore

@main
struct ClaudexApp: App {
    @StateObject private var model: AppModel
    init() {
        #if DEBUG
        if let state = ProcessInfo.processInfo.environment["CLAUDEX_UI_FIXTURE"] {
            _model = StateObject(wrappedValue: AppModel.visualFixture(state)); return
        }
        #endif
        _model = StateObject(wrappedValue: AppModel())
    }
    @AppStorage("claudex.appearance") private var appearanceRaw: Int = 0

    private var preferredColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLAUDEX_UI_FIXTURE"] != nil {
            return ProcessInfo.processInfo.environment["CLAUDEX_UI_APPEARANCE"] == "light" ? .light : .dark
        }
        #endif
        switch appearanceRaw {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        MenuBarExtra("Claudex", systemImage: "terminal.fill") {
            ContentView(model: model)
                .preferredColorScheme(preferredColorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            DoctorSettingsView(model: model)
                .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 660)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
