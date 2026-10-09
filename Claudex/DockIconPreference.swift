import AppKit
import Combine

@MainActor final class DockIconPreference: ObservableObject {
    static let key = "claudex.showDockIcon"
    static let shared = DockIconPreference()

    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Self.key)
            apply()
        }
    }

    private let defaults: UserDefaults
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let captureForegroundWindow: @MainActor () -> (@MainActor () -> Void)?

    init(
        defaults: UserDefaults = .standard,
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = {
            NSApplication.shared.setActivationPolicy($0)
        },
        captureForegroundWindow: @escaping @MainActor () -> (@MainActor () -> Void)? = {
            let app = NSApplication.shared
            guard app.isActive, app.activationPolicy() == .regular, let window = app.keyWindow ?? app.mainWindow,
                  window.isVisible, !window.isMiniaturized else { return nil }
            let responder = window.firstResponder
            let wasMain = window.isMainWindow
            let transition = DockForegroundTransition(app: app, window: window,
                                                      responder: responder, wasMain: wasMain)
            transition.observe()
            return { transition.completePolicyChange() }
        }
    ) {
        self.defaults = defaults
        self.applyPolicy = applyPolicy
        self.captureForegroundWindow = captureForegroundWindow
        showDockIcon = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func apply() {
        DockForegroundTransition.cancelPending()
        let restoreForegroundWindow = captureForegroundWindow()
        applyPolicy(showDockIcon ? .regular : .accessory)
        restoreForegroundWindow?()
    }
}

@MainActor private final class DockForegroundTransition {
    private static var pending: DockForegroundTransition?
    private let app: NSApplication
    private weak var window: NSWindow?
    private let responder: NSResponder?
    private let wasMain: Bool
    private var observers: [NSObjectProtocol] = []

    init(app: NSApplication, window: NSWindow, responder: NSResponder?, wasMain: Bool) {
        self.app = app
        self.window = window
        self.responder = responder
        self.wasMain = wasMain
    }

    static func cancelPending() { pending?.cancel() }

    func observe() {
        Self.pending?.cancel()
        Self.pending = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: app, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, Self.pending === self else { return }
                    self.app.activate(ignoringOtherApps: true)
                }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: app, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    func completePolicyChange() {
        if app.activationPolicy() != .accessory { cancel() }
    }

    private func restore() {
        guard let window, window.isVisible else { cancel(); return }
        cancel()
        window.makeKeyAndOrderFront(nil)
        if wasMain { window.makeMain() }
        if let responder { window.makeFirstResponder(responder) }
        cancel()
    }

    private func cancel() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if Self.pending === self { Self.pending = nil }
    }
}

@MainActor final class ClaudexAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let model else { return .terminateNow }
        terminationPending = true
        Task {
            await model.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconPreference.shared.apply()
    }
}
