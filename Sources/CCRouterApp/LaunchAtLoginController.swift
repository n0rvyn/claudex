import ServiceManagement

@MainActor
final class LaunchAtLoginController {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    var statusText: String {
        switch service.status {
        case .notRegistered:
            "Launch at login is off"
        case .enabled:
            "Launch at login is on"
        case .requiresApproval:
            "Launch at login needs approval in System Settings"
        case .notFound:
            "Launch at login needs the packaged app bundle"
        @unknown default:
            "Launch at login returned an unknown status"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
