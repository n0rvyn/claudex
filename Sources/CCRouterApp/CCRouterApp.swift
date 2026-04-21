import AppKit
import CCRouterCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var daemonState = "stopped"
    @Published private(set) var endpoint = "http://127.0.0.1:4317"
    @Published private(set) var statusText = "Daemon stopped"
    @Published private(set) var authText = "Auth unknown"
    @Published private(set) var gatewayTokenText = "Token unknown"
    @Published private(set) var configurationPath = ""
    @Published private(set) var configurationWarning: String?
    @Published private(set) var subscriptionAuthFilePath = ""
    @Published private(set) var envSnippet = ""
    @Published private(set) var tracePath = UserHomeResolver.defaultTraceLogFilePath()
    @Published private(set) var recentTraceLines: [String] = []
    @Published private(set) var doctorNotes: [String] = []
    @Published private(set) var traceStageCounts: [String: Int] = [:]
    @Published private(set) var recentFunctionCallNames: [String] = []
    @Published private(set) var recentConnectorNames: [String] = []
    @Published private(set) var recentRejectedPaths: [String] = []
    @Published private(set) var launchAtLoginText = "Launch at login unknown"
    @Published private(set) var launchAtLoginEnabled = false

    private let configurationStore = RouterConfigurationStore()
    private let launchAtLoginController = LaunchAtLoginController()
    private var daemon = GatewayDaemon()

    init() {
        refreshLocalConfiguration()
    }

    func startDaemon() {
        Task {
            do {
                try await daemon.start()
                await refreshSnapshot(runningText: "Daemon running")
            } catch {
                statusText = "Failed to start daemon: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        Task {
            await daemon.stop()
            daemonState = "stopped"
            statusText = "Daemon stopped"
            authText = "Auth unknown"
        }
    }

    func refresh() {
        Task {
            await refreshSnapshot(runningText: statusText)
        }
    }

    func copyEnvSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(envSnippet, forType: .string)
        statusText = "Claude environment copied"
    }

    func toggleLaunchAtLogin() {
        do {
            try launchAtLoginController.setEnabled(!launchAtLoginEnabled)
            refreshLaunchAtLogin()
            statusText = launchAtLoginText
        } catch {
            statusText = "Launch at login update failed: \(error.localizedDescription)"
        }
    }

    private func refreshSnapshot(runningText: String) async {
        refreshLocalConfiguration()
        refreshLaunchAtLogin()
        let snapshot = await daemon.snapshot()
        daemonState = snapshot.daemonState
        endpoint = "http://\(snapshot.host):\(snapshot.port)"
        statusText = runningText
        tracePath = snapshot.tracePath
        recentTraceLines = snapshot.recentTraceLines
        configurationPath = snapshot.configurationPath
        configurationWarning = snapshot.configurationWarning
        subscriptionAuthFilePath = snapshot.subscriptionAuthFilePath
        gatewayTokenText = "\(snapshot.gatewayAuthHeader) ready (\(snapshot.gatewayAuthTokenSuffix))"
        traceStageCounts = snapshot.traceDiagnostics.recentStageCounts
        recentFunctionCallNames = snapshot.traceDiagnostics.recentFunctionCallNames
        recentConnectorNames = snapshot.traceDiagnostics.recentConnectorNames
        recentRejectedPaths = snapshot.traceDiagnostics.recentRejectedPaths
        if snapshot.chatGPTAuthenticated {
            authText = "ChatGPT auth ready (\(snapshot.accountIDSuffix ?? "unknown"))"
        } else {
            authText = snapshot.authError ?? "ChatGPT auth missing"
        }
        doctorNotes = makeDoctorNotes(configurationWarning: snapshot.configurationWarning)
    }

    private func refreshLocalConfiguration() {
        let configuration = configurationStore.loadOrCreate()
        endpoint = configuration.endpoint
        envSnippet = configuration.claudeEnvironmentSnippet
        configurationPath = configuration.configurationPath
        configurationWarning = configuration.configurationWarning
        subscriptionAuthFilePath = configuration.subscriptionAuthFilePath
        gatewayTokenText = "\(configuration.gatewayAuthHeader) ready (\(configuration.gatewayAuthTokenSuffix))"
        doctorNotes = makeDoctorNotes(configurationWarning: configuration.configurationWarning)
        refreshLaunchAtLogin()
    }

    private func makeDoctorNotes(configurationWarning: String?) -> [String] {
        var notes = [
            "Claude Code integration uses ANTHROPIC_BASE_URL -> local gateway.",
            "Local gateway forwards Anthropic Messages to chatgpt.com/backend-api/codex/responses.",
            "Ingress auth is enforced through x-api-key from ANTHROPIC_AUTH_TOKEN.",
            "Launch at login uses SMAppService.mainApp from the packaged app bundle.",
            "Validated paths: default text, bare text, Bash, Read, advisor, Notion auth.",
        ]
        if let configurationWarning, !configurationWarning.isEmpty {
            notes.append(configurationWarning)
        }
        return notes
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginEnabled = launchAtLoginController.isEnabled
        launchAtLoginText = launchAtLoginController.statusText
    }
}

@main
struct CCRouterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("ModelBridge", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 12) {
                Text("ModelBridge")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Daemon", value: model.daemonState)
                    LabeledContent("Endpoint", value: model.endpoint)
                    LabeledContent("Auth", value: model.authText)
                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Start Daemon") {
                        model.startDaemon()
                    }

                    Button("Stop Daemon") {
                        model.stopDaemon()
                    }

                    Button("Refresh") {
                        model.refresh()
                    }

                    Button("Copy Env") {
                        model.copyEnvSnippet()
                    }
                }

                HStack {
                    Button(model.launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                        model.toggleLaunchAtLogin()
                    }
                    Text(model.launchAtLoginText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude CLI")
                        .font(.headline)
                    Text(model.envSnippet)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.gatewayTokenText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Doctor")
                        .font(.headline)
                    ForEach(model.doctorNotes, id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Config: \(model.configurationPath)")
                        .font(.footnote)
                        .textSelection(.enabled)
                    Text("Subscription auth: \(model.subscriptionAuthFilePath)")
                        .font(.footnote)
                        .textSelection(.enabled)
                    Text("Trace: \(model.tracePath)")
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                if !model.recentTraceLines.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent Trace")
                            .font(.headline)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(model.recentTraceLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 140, maxHeight: 220)
                    }
                }

                if !model.traceStageCounts.isEmpty || !model.recentFunctionCallNames.isEmpty || !model.recentConnectorNames.isEmpty || !model.recentRejectedPaths.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connector Diagnostics")
                            .font(.headline)
                        if !model.traceStageCounts.isEmpty {
                            Text("Recent stages: \(formatPairs(model.traceStageCounts))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentFunctionCallNames.isEmpty {
                            Text("Function calls: \(model.recentFunctionCallNames.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentConnectorNames.isEmpty {
                            Text("Connectors: \(model.recentConnectorNames.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentRejectedPaths.isEmpty {
                            Text("Rejected paths: \(model.recentRejectedPaths.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
            .frame(minWidth: 380)
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("CC Router Doctor")
                    .font(.headline)
                Text("Use the menu bar item to start the local daemon.")
                Text("Claude Code should point ANTHROPIC_BASE_URL to the endpoint shown there.")
                Text("Use the generated ANTHROPIC_AUTH_TOKEN shown in the environment snippet.")
                Text("Recent verified paths: default text, bare text, Bash, Read, advisor, Notion auth.")
                    .foregroundStyle(.secondary)
                Text(model.launchAtLoginText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Config path: \(model.configurationPath)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Subscription auth: \(model.subscriptionAuthFilePath)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Trace path: \(model.tracePath)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text(model.envSnippet)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)

                if !model.traceStageCounts.isEmpty || !model.recentFunctionCallNames.isEmpty || !model.recentConnectorNames.isEmpty || !model.recentRejectedPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !model.traceStageCounts.isEmpty {
                            Text("Recent stages: \(formatPairs(model.traceStageCounts))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentFunctionCallNames.isEmpty {
                            Text("Function calls: \(model.recentFunctionCallNames.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentConnectorNames.isEmpty {
                            Text("Connectors: \(model.recentConnectorNames.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !model.recentRejectedPaths.isEmpty {
                            Text("Rejected paths: \(model.recentRejectedPaths.joined(separator: ", "))")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !model.recentTraceLines.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.recentTraceLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320)
                }
            }
            .padding()
            .frame(minWidth: 560, minHeight: 360)
        }
    }
}

private func formatPairs(_ values: [String: Int]) -> String {
    values.keys.sorted().map { key in
        "\(key)=\(values[key] ?? 0)"
    }
    .joined(separator: ", ")
}
