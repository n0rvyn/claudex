import AppKit
import Combine
import CCRouterCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var daemonState = "stopped"
    @Published private(set) var endpoint = "http://127.0.0.1:4317"
    @Published private(set) var statusText = "ModelBridge daemon stopped"
    @Published private(set) var authText = "Auth unknown"
    @Published private(set) var gatewayTokenText = "Token unknown"
    @Published private(set) var configurationPath = ""
    @Published private(set) var configurationWarning: String?
    @Published private(set) var subscriptionAuthFilePath = ""
    @Published private(set) var envSnippet = ""
    @Published private(set) var tracePath = "/tmp/modelbridge-trace.jsonl"
    @Published private(set) var recentTraceLines: [String] = []
    @Published private(set) var doctorNotes: [String] = []
    @Published private(set) var traceStageCounts: [String: Int] = [:]
    @Published private(set) var recentFunctionCallNames: [String] = []
    @Published private(set) var recentConnectorNames: [String] = []
    @Published private(set) var recentRejectedPaths: [String] = []
    @Published private(set) var recentRequestCount = 0
    @Published private(set) var recentSuccessCount = 0
    @Published private(set) var recentFailureCount = 0
    @Published private(set) var requestsPerMinute = 0.0
    @Published private(set) var lastRequestOutcome = "No recent request"
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var p50LatencyMilliseconds: Int?
    @Published private(set) var p95LatencyMilliseconds: Int?
    @Published private(set) var recentErrorReasons: [String] = []
    @Published private(set) var launchAtLoginText = "Launch at login unknown"
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var currentConfiguration: RouterConfiguration

    @Published var gatewayHostDraft: String
    @Published var gatewayPortDraft: String
    @Published var responsesURLDraft: String
    @Published var executorModelDraft: String
    @Published var advisorModelDraft: String
    @Published var subscriptionAuthFilePathDraft: String

    private let configurationStore = RouterConfigurationStore()
    private let launchAtLoginController = LaunchAtLoginController()
    private var daemon: GatewayDaemon
    private var refreshCancellable: AnyCancellable?

    init() {
        let configuration = RouterConfigurationStore().loadOrCreate()
        self.currentConfiguration = configuration
        self.gatewayHostDraft = configuration.host
        self.gatewayPortDraft = String(configuration.port)
        self.responsesURLDraft = configuration.responsesURL
        self.executorModelDraft = configuration.executorModel
        self.advisorModelDraft = configuration.advisorModel
        self.subscriptionAuthFilePathDraft = configuration.subscriptionAuthFilePath
        self.daemon = GatewayDaemon(configuration: configuration)
        applyConfigurationStatus(configuration)
        syncDrafts(configuration)
        refreshLaunchAtLogin()
        refresh()
        refreshCancellable = Timer
            .publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    var daemonIsRunning: Bool {
        daemonState == "running"
    }

    fileprivate var statusTone: DashboardTone {
        if daemonState != "running" { return .warning }
        if !isUpstreamReady { return .warning }
        if recentFailureCount > 0 { return .danger }
        return .success
    }

    var isUpstreamReady: Bool {
        authText.hasPrefix("ChatGPT auth ready")
    }

    var reliabilityRate: Double {
        guard recentRequestCount > 0 else { return 1 }
        return Double(recentSuccessCount) / Double(recentRequestCount)
    }

    var errorRate: Double {
        guard recentRequestCount > 0 else { return 0 }
        return Double(recentFailureCount) / Double(recentRequestCount)
    }

    var heroSummary: String {
        if daemonState != "running" {
            return "Daemon offline"
        }
        if !isUpstreamReady {
            return "Upstream attention needed"
        }
        if recentFailureCount > 0 {
            return "Requests are reaching ModelBridge with recent failures"
        }
        return "Gateway healthy"
    }

    var endpointShortLabel: String {
        endpoint.replacingOccurrences(of: "http://", with: "")
    }

    func startDaemon() {
        Task {
            do {
                try await daemon.start()
                await refreshSnapshot(runningText: "ModelBridge daemon running")
            } catch {
                statusText = "Failed to start daemon: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        Task {
            await daemon.stop()
            daemonState = "stopped"
            statusText = "ModelBridge daemon stopped"
            authText = "Auth unknown"
        }
    }

    func restartDaemon() {
        Task {
            await daemon.stop()
            daemon = GatewayDaemon(configuration: currentConfiguration)
            do {
                try await daemon.start()
                await refreshSnapshot(runningText: "ModelBridge daemon restarted")
            } catch {
                statusText = "Failed to restart daemon: \(error.localizedDescription)"
            }
        }
    }

    func refresh() {
        Task {
            await refreshSnapshot(runningText: statusText)
        }
    }

    func copyEnvSnippet() {
        copyToPasteboard(envSnippet)
        statusText = "Claude environment copied"
    }

    func copyGatewayToken() {
        copyToPasteboard(currentConfiguration.gatewayAuthToken)
        statusText = "Gateway token copied"
    }

    func copyEndpoint() {
        copyToPasteboard(endpoint)
        statusText = "Gateway endpoint copied"
    }

    func copyDiagnosticsSummary() {
        copyToPasteboard(diagnosticsSummary)
        statusText = "Diagnostics summary copied"
    }

    func openConfigurationLocation() {
        revealPath(configurationPath)
    }

    func openSubscriptionAuthLocation() {
        revealPath(subscriptionAuthFilePath)
    }

    func openTraceLocation() {
        revealPath(tracePath)
    }

    func openApplicationSupportDirectory() {
        let directory = URL(fileURLWithPath: configurationPath).deletingLastPathComponent().path
        revealPath(directory)
    }

    func saveGatewaySettings() {
        guard let port = Int(gatewayPortDraft), (1...65_535).contains(port) else {
            statusText = "Port must be between 1 and 65535"
            return
        }
        persistConfiguration(
            host: gatewayHostDraft,
            port: port,
            responsesURL: responsesURLDraft,
            executorModel: executorModelDraft,
            advisorModel: advisorModelDraft,
            subscriptionAuthFilePath: subscriptionAuthFilePathDraft,
            statusMessage: "Gateway settings saved"
        )
    }

    func saveUpstreamSettings() {
        guard let port = Int(gatewayPortDraft), (1...65_535).contains(port) else {
            statusText = "Port must be between 1 and 65535"
            return
        }
        persistConfiguration(
            host: gatewayHostDraft,
            port: port,
            responsesURL: responsesURLDraft,
            executorModel: executorModelDraft,
            advisorModel: advisorModelDraft,
            subscriptionAuthFilePath: subscriptionAuthFilePathDraft,
            statusMessage: "Upstream settings saved"
        )
    }

    func regenerateGatewayToken() {
        Task {
            let wasRunning = daemonIsRunning
            let saved = configurationStore.regenerateGatewayToken(from: currentConfiguration)
            await replaceDaemon(with: saved, restartIfRunning: wasRunning)
            syncDrafts(saved)
            statusText = "Gateway token regenerated"
        }
    }

    func reloadPersistedConfiguration() {
        let configuration = configurationStore.loadOrCreate()
        currentConfiguration = configuration
        applyConfigurationStatus(configuration)
        syncDrafts(configuration)
        refreshLaunchAtLogin()
        statusText = "Configuration reloaded"
        refresh()
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

    private func persistConfiguration(
        host: String,
        port: Int,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        subscriptionAuthFilePath: String,
        statusMessage: String
    ) {
        Task {
            let wasRunning = daemonIsRunning
            let saved = configurationStore.save(
                configuration: RouterConfiguration(
                    host: host,
                    port: port,
                    healthPath: currentConfiguration.healthPath,
                    messagesPath: currentConfiguration.messagesPath,
                    countTokensPath: currentConfiguration.countTokensPath,
                    responsesURL: responsesURL,
                    executorModel: executorModel,
                    advisorModel: advisorModel,
                    gatewayAuthToken: currentConfiguration.gatewayAuthToken,
                    gatewayAuthHeader: currentConfiguration.gatewayAuthHeader,
                    subscriptionAuthFilePath: subscriptionAuthFilePath,
                    configurationPath: currentConfiguration.configurationPath,
                    configurationWarning: currentConfiguration.configurationWarning
                )
            )
            await replaceDaemon(with: saved, restartIfRunning: wasRunning)
            syncDrafts(saved)
            statusText = wasRunning ? "\(statusMessage); daemon restarted" : statusMessage
        }
    }

    private func replaceDaemon(with configuration: RouterConfiguration, restartIfRunning: Bool) async {
        if restartIfRunning {
            await daemon.stop()
        }
        currentConfiguration = configuration
        applyConfigurationStatus(configuration)
        daemon = GatewayDaemon(configuration: configuration)
        if restartIfRunning {
            do {
                try await daemon.start()
            } catch {
                statusText = "Saved, but failed to restart daemon: \(error.localizedDescription)"
            }
        }
        await refreshSnapshot(runningText: statusText)
    }

    private func refreshSnapshot(runningText: String) async {
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
        recentRequestCount = snapshot.traceDiagnostics.recentRequestCount
        recentSuccessCount = snapshot.traceDiagnostics.recentSuccessCount
        recentFailureCount = snapshot.traceDiagnostics.recentFailureCount
        requestsPerMinute = snapshot.traceDiagnostics.requestsPerMinute
        lastRequestOutcome = humanizeOutcome(snapshot.traceDiagnostics.lastRequestOutcome)
        lastLatencyMilliseconds = snapshot.traceDiagnostics.lastLatencyMilliseconds
        p50LatencyMilliseconds = snapshot.traceDiagnostics.p50LatencyMilliseconds
        p95LatencyMilliseconds = snapshot.traceDiagnostics.p95LatencyMilliseconds
        recentErrorReasons = snapshot.traceDiagnostics.recentErrorReasons
        if snapshot.chatGPTAuthenticated {
            authText = "ChatGPT auth ready (\(snapshot.accountIDSuffix ?? "unknown"))"
        } else {
            authText = snapshot.authError ?? "ChatGPT auth missing"
        }
        doctorNotes = makeDoctorNotes(configurationWarning: snapshot.configurationWarning)
    }

    private func applyConfigurationStatus(_ configuration: RouterConfiguration) {
        currentConfiguration = configuration
        endpoint = configuration.endpoint
        envSnippet = configuration.claudeEnvironmentSnippet
        configurationPath = configuration.configurationPath
        configurationWarning = configuration.configurationWarning
        subscriptionAuthFilePath = configuration.subscriptionAuthFilePath
        gatewayTokenText = "\(configuration.gatewayAuthHeader) ready (\(configuration.gatewayAuthTokenSuffix))"
        doctorNotes = makeDoctorNotes(configurationWarning: configuration.configurationWarning)
    }

    private func syncDrafts(_ configuration: RouterConfiguration) {
        gatewayHostDraft = configuration.host
        gatewayPortDraft = String(configuration.port)
        responsesURLDraft = configuration.responsesURL
        executorModelDraft = configuration.executorModel
        advisorModelDraft = configuration.advisorModel
        subscriptionAuthFilePathDraft = configuration.subscriptionAuthFilePath
    }

    private func makeDoctorNotes(configurationWarning: String?) -> [String] {
        var notes = [
            "Claude Code uses ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN from this app.",
            "ModelBridge forwards Anthropic Messages to chatgpt.com/backend-api/codex/responses.",
            "Ingress auth is enforced through x-api-key.",
            "Settings changes restart the daemon automatically when it is already running.",
            "Validated paths include default text, Bash, Read, advisor, and Notion auth.",
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

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func humanizeOutcome(_ outcome: String?) -> String {
        switch outcome {
        case "initial":
            return "Last request completed"
        case "advisor_or_tools":
            return "Tool or advisor path active"
        case "continuation":
            return "Continuation completed"
        case "responses_http_error":
            return "Upstream HTTP error"
        case "subscription_error":
            return "Subscription auth error"
        case "decode_or_bridge_error":
            return "Gateway request error"
        case "auth_rejected":
            return "Local auth rejected"
        case nil:
            return "No recent request"
        default:
            return outcome ?? "No recent request"
        }
    }

    var diagnosticsSummary: String {
        [
            "Daemon: \(daemonState)",
            "Endpoint: \(endpoint)",
            "Auth: \(authText)",
            "Last request: \(lastRequestOutcome)",
            "Requests: \(recentRequestCount)",
            "Successes: \(recentSuccessCount)",
            "Failures: \(recentFailureCount)",
            "Requests/min: \(formattedRequestsPerMinute)",
            "Latency p50/p95: \(latencySummary)",
            "Connectors: \(recentConnectorNames.joined(separator: ", "))",
            "Function calls: \(recentFunctionCallNames.joined(separator: ", "))",
            "Errors: \(recentErrorReasons.joined(separator: " | "))",
            "Trace: \(tracePath)",
        ].joined(separator: "\n")
    }

    var formattedRequestsPerMinute: String {
        String(format: "%.1f", requestsPerMinute)
    }

    var latencySummary: String {
        let p50 = p50LatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
        let p95 = p95LatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
        return "\(p50) / \(p95)"
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: DashboardTokens.gridSpacing),
        GridItem(.flexible(), spacing: DashboardTokens.gridSpacing),
        GridItem(.flexible(), spacing: DashboardTokens.gridSpacing),
    ]

    var body: some View {
        ZStack {
            DashboardPalette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DashboardTokens.sectionSpacing) {
                    DashboardHeroCard(model: model)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: DashboardTokens.gridSpacing) {
                        MetricCard(
                            title: "Traffic",
                            value: "\(model.recentRequestCount)",
                            detail: "\(model.formattedRequestsPerMinute) req/min",
                            symbol: "waveform.path.ecg.rectangle",
                            tone: .info
                        )
                        MetricCard(
                            title: "Latency",
                            value: model.lastLatencyMilliseconds.map { "\($0) ms" } ?? "n/a",
                            detail: "p50/p95 \(model.latencySummary)",
                            symbol: "timer",
                            tone: .accent
                        )
                        MetricCard(
                            title: "Reliability",
                            value: PercentFormatter.string(for: 1 - model.errorRate),
                            detail: "\(model.recentFailureCount) recent failure\(model.recentFailureCount == 1 ? "" : "s")",
                            symbol: "checkmark.shield",
                            tone: model.recentFailureCount > 0 ? .warning : .success
                        )
                    }
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .top, spacing: DashboardTokens.gridSpacing) {
                        ActivityCard(
                            title: "Runtime Activity",
                            subtitle: "Recent tools and connector activity",
                            items: activityRows,
                            tone: .accent
                        )
                        ActivityCard(
                            title: "Operational Notes",
                            subtitle: "Live issues and guidance",
                            items: noteRows,
                            tone: model.recentFailureCount > 0 ? .warning : .info
                        )
                    }
                    .frame(maxWidth: .infinity)

                    FeedCard(
                        title: "Live Feed",
                        subtitle: "Recent trace events from the local gateway",
                        lines: model.recentTraceLines
                    )

                    DashboardActionBar(model: model)
                }
                .padding(DashboardTokens.outerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activityRows: [ActivityRow] {
        var rows: [ActivityRow] = []
        if !model.recentFunctionCallNames.isEmpty {
            rows.append(ActivityRow(
                title: "Tools",
                value: model.recentFunctionCallNames.prefix(4).joined(separator: ", "),
                tone: .accent
            ))
        }
        if !model.recentConnectorNames.isEmpty {
            rows.append(ActivityRow(
                title: "Connectors",
                value: model.recentConnectorNames.prefix(4).joined(separator: ", "),
                tone: .success
            ))
        }
        if !model.recentRejectedPaths.isEmpty {
            rows.append(ActivityRow(
                title: "Rejected Paths",
                value: model.recentRejectedPaths.prefix(3).joined(separator: ", "),
                tone: .warning
            ))
        }
        if rows.isEmpty {
            rows.append(ActivityRow(title: "Runtime", value: "No recent tool or connector activity", tone: .info))
        }
        return rows
    }

    private var noteRows: [ActivityRow] {
        var rows = [
            ActivityRow(title: "Status", value: model.statusText, tone: model.statusTone),
            ActivityRow(title: "Auth", value: model.authText, tone: model.isUpstreamReady ? .success : .warning),
        ]
        if let configurationWarning = model.configurationWarning, !configurationWarning.isEmpty {
            rows.append(ActivityRow(title: "Config", value: configurationWarning, tone: .warning))
        }
        if !model.recentErrorReasons.isEmpty {
            rows.append(ActivityRow(title: "Recent Errors", value: model.recentErrorReasons.prefix(2).joined(separator: " • "), tone: .danger))
        }
        return rows
    }
}

struct DoctorSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = SettingsTab.overview

    var body: some View {
        ZStack {
            DashboardPalette.settingsCanvas.ignoresSafeArea()

            TabView(selection: $selectedTab) {
                SettingsTabShell(
                    title: "Overview",
                    subtitle: "Current system state, health summary, and the fastest path into the local routing stack."
                ) {
                    OverviewSettingsTab(model: model)
                }
                .tag(SettingsTab.overview)
                .tabItem {
                    Label("Overview", systemImage: "rectangle.grid.1x2")
                }

                SettingsTabShell(
                    title: "Gateway",
                    subtitle: "Control the local daemon, endpoint, token lifecycle, and runtime boundary."
                ) {
                    GatewaySettingsTab(model: model)
                }
                .tag(SettingsTab.gateway)
                .tabItem {
                    Label("Gateway", systemImage: "dot.radiowaves.left.and.right")
                }

                SettingsTabShell(
                    title: "Claude Code",
                    subtitle: "Use these values directly with Claude Code through ANTHROPIC_BASE_URL."
                ) {
                    ClaudeCodeSettingsTab(model: model)
                }
                .tag(SettingsTab.claudeCode)
                .tabItem {
                    Label("Claude Code", systemImage: "terminal")
                }

                SettingsTabShell(
                    title: "Upstream",
                    subtitle: "Manage the subscription-backed execution path and model selection."
                ) {
                    UpstreamSettingsTab(model: model)
                }
                .tag(SettingsTab.upstream)
                .tabItem {
                    Label("Upstream", systemImage: "network")
                }

                SettingsTabShell(
                    title: "Diagnostics",
                    subtitle: "Inspect trace health, request outcomes, connector activity, and exportable diagnostics."
                ) {
                    DiagnosticsSettingsTab(model: model)
                }
                .tag(SettingsTab.diagnostics)
                .tabItem {
                    Label("Diagnostics", systemImage: "waveform.and.magnifyingglass")
                }

                SettingsTabShell(
                    title: "Advanced",
                    subtitle: "System-level behaviors, launch options, and low-frequency maintenance actions."
                ) {
                    AdvancedSettingsTab(model: model)
                }
                .tag(SettingsTab.advanced)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private enum SettingsTab: Hashable {
    case overview
    case gateway
    case claudeCode
    case upstream
    case diagnostics
    case advanced
}

private enum DashboardTone {
    case success
    case warning
    case danger
    case accent
    case info

    var color: Color {
        switch self {
        case .success:
            return DashboardPalette.success
        case .warning:
            return DashboardPalette.warning
        case .danger:
            return DashboardPalette.danger
        case .accent:
            return DashboardPalette.accent
        case .info:
            return DashboardPalette.info
        }
    }
}

private enum DashboardTokens {
    static let outerPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 16
    static let feedHeight: CGFloat = 220
}

private enum DashboardPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let settingsCanvas = Color(nsColor: .underPageBackgroundColor)
    static let elevated = Color(nsColor: .controlBackgroundColor)
    static let secondarySurface = Color.black.opacity(0.10)
    static let ink = Color.white.opacity(0.96)
    static let mutedInk = Color.white.opacity(0.72)
    static let quietInk = Color.primary.opacity(0.72)
    static let accent = Color(red: 0.27, green: 0.68, blue: 0.98)
    static let info = Color(red: 0.40, green: 0.75, blue: 0.98)
    static let success = Color(red: 0.29, green: 0.82, blue: 0.55)
    static let warning = Color(red: 0.96, green: 0.71, blue: 0.25)
    static let danger = Color(red: 0.98, green: 0.43, blue: 0.38)
    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.13, blue: 0.22),
            Color(red: 0.12, green: 0.29, blue: 0.42),
            Color(red: 0.08, green: 0.42, blue: 0.44),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let dashboardCardGradient = LinearGradient(
        colors: [
            Color(red: 0.16, green: 0.18, blue: 0.23),
            Color(red: 0.12, green: 0.14, blue: 0.18),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let settingsCard = Color(nsColor: .windowBackgroundColor)
}

private struct DashboardHeroCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ModelBridge")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(DashboardPalette.ink)
                    Text(model.heroSummary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DashboardPalette.mutedInk)
                }
                Spacer()
                StatusBadge(title: model.daemonIsRunning ? "Live" : "Idle", tone: model.statusTone)
            }

            HStack(spacing: 8) {
                StatusBadge(title: model.daemonIsRunning ? "Daemon Online" : "Daemon Offline", tone: model.daemonIsRunning ? .success : .warning)
                StatusBadge(title: model.isUpstreamReady ? "Upstream Ready" : "Upstream Missing", tone: model.isUpstreamReady ? .success : .warning)
                StatusBadge(title: model.lastRequestOutcome, tone: model.recentFailureCount > 0 ? .warning : .accent)
            }

            VStack(alignment: .leading, spacing: 10) {
                KeyValuePill(label: "Endpoint", value: model.endpointShortLabel)
                HStack(spacing: 10) {
                    KeyValuePill(label: "Executor", value: model.currentConfiguration.executorModel)
                    KeyValuePill(label: "Advisor", value: model.currentConfiguration.advisorModel)
                }
            }

            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(DashboardPalette.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DashboardTokens.cardPadding)
        .frame(maxWidth: .infinity)
        .background(DashboardPalette.heroGradient, in: RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: DashboardTone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(DashboardPalette.mutedInk)
                Spacer()
                Circle()
                    .fill(tone.color)
                    .frame(width: 9, height: 9)
            }

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DashboardPalette.ink)

            Text(detail)
                .font(.footnote)
                .foregroundStyle(DashboardPalette.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DashboardTokens.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(DashboardPalette.dashboardCardGradient, in: RoundedRectangle(cornerRadius: DashboardTokens.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardTokens.smallCornerRadius, style: .continuous)
                .stroke(tone.color.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ActivityRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tone: DashboardTone
}

private struct ActivityCard: View {
    let title: String
    let subtitle: String
    let items: [ActivityRow]
    let tone: DashboardTone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DashboardPalette.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(DashboardPalette.mutedInk)
            }

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(DashboardPalette.mutedInk)
                        Spacer()
                        Circle()
                            .fill(item.tone.color)
                            .frame(width: 8, height: 8)
                    }
                    Text(item.value)
                        .font(.subheadline)
                        .foregroundStyle(DashboardPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(DashboardTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DashboardPalette.dashboardCardGradient, in: RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous)
                .stroke(tone.color.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct FeedCard: View {
    let title: String
    let subtitle: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DashboardPalette.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(DashboardPalette.mutedInk)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("No recent trace events yet.")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DashboardPalette.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: DashboardTokens.feedHeight, maxHeight: DashboardTokens.feedHeight)
            .padding(12)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: DashboardTokens.smallCornerRadius, style: .continuous))
        }
        .padding(DashboardTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardPalette.dashboardCardGradient, in: RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct DashboardActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ActionButton(
                title: model.daemonIsRunning ? "Restart" : "Start",
                systemImage: model.daemonIsRunning ? "arrow.clockwise" : "play.fill",
                tone: .accent
            ) {
                if model.daemonIsRunning {
                    model.restartDaemon()
                } else {
                    model.startDaemon()
                }
            }

            ActionButton(title: "Refresh", systemImage: "arrow.trianglehead.clockwise", tone: .info) {
                model.refresh()
            }

            ActionButton(title: "Copy Env", systemImage: "doc.on.doc", tone: .success) {
                model.copyEnvSnippet()
            }

            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(tone: .warning))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsTabShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OverviewSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "System Summary", subtitle: "The shortest path to current runtime state.") {
                VStack(alignment: .leading, spacing: 10) {
                    SummaryLine(label: "Daemon", value: model.daemonState)
                    SummaryLine(label: "Endpoint", value: model.endpoint)
                    SummaryLine(label: "Auth", value: model.authText)
                    SummaryLine(label: "Last request", value: model.lastRequestOutcome)
                    SummaryLine(label: "Requests/min", value: model.formattedRequestsPerMinute)
                    SummaryLine(label: "Latency", value: model.latencySummary)
                }
            }

            SettingsCard(title: "Quick Actions", subtitle: "Common operations without opening the menu bar dashboard.") {
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: model.daemonIsRunning ? "Restart Daemon" : "Start Daemon", systemImage: model.daemonIsRunning ? "arrow.clockwise" : "play.fill") {
                        if model.daemonIsRunning {
                            model.restartDaemon()
                        } else {
                            model.startDaemon()
                        }
                    }
                    SecondarySettingsButton(title: "Copy Env", systemImage: "doc.on.doc") {
                        model.copyEnvSnippet()
                    }
                    SecondarySettingsButton(title: "Open Trace", systemImage: "text.append") {
                        model.openTraceLocation()
                    }
                }
            }

            SettingsCard(title: "Routing Path", subtitle: "This is the fixed product path of ModelBridge.") {
                CodeBlock(value: "Claude Code CLI -> ANTHROPIC_BASE_URL -> ModelBridge -> chatgpt.com/backend-api/codex/responses")
            }
        }
    }
}

private struct GatewaySettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Local Gateway", subtitle: "Host, port, daemon control, and ingress token lifecycle.") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsTextField(title: "Host", text: $model.gatewayHostDraft)
                    SettingsTextField(title: "Port", text: $model.gatewayPortDraft)
                    SummaryLine(label: "Current endpoint", value: model.endpoint)
                    SummaryLine(label: "Gateway token", value: model.gatewayTokenText)
                }
            }

            SettingsCard(title: "Gateway Actions", subtitle: "Changes here restart the daemon automatically when it is already running.") {
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: "Save Gateway", systemImage: "tray.and.arrow.down") {
                        model.saveGatewaySettings()
                    }
                    SecondarySettingsButton(title: "Regenerate Token", systemImage: "key") {
                        model.regenerateGatewayToken()
                    }
                    SecondarySettingsButton(title: "Copy Endpoint", systemImage: "link") {
                        model.copyEndpoint()
                    }
                    SecondarySettingsButton(title: "Copy Token", systemImage: "lock.doc") {
                        model.copyGatewayToken()
                    }
                }
            }

            SettingsCard(title: "Configuration Files", subtitle: "Useful local paths for support and inspection.") {
                VStack(alignment: .leading, spacing: 10) {
                    CodeBlock(value: model.configurationPath)
                    HStack(spacing: 12) {
                        SecondarySettingsButton(title: "Reveal Config", systemImage: "folder") {
                            model.openConfigurationLocation()
                        }
                        SecondarySettingsButton(title: "Reveal Support Folder", systemImage: "folder.badge.gearshape") {
                            model.openApplicationSupportDirectory()
                        }
                    }
                }
            }
        }
    }
}

private struct ClaudeCodeSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Claude CLI Environment", subtitle: "Use this exact snippet with Claude Code.") {
                CodeBlock(value: model.envSnippet)
            }

            SettingsCard(title: "Copy Helpers", subtitle: "The fastest way to move from configuration to active Claude sessions.") {
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: "Copy Full Env", systemImage: "doc.on.doc") {
                        model.copyEnvSnippet()
                    }
                    SecondarySettingsButton(title: "Copy Base URL", systemImage: "network") {
                        model.copyEndpoint()
                    }
                    SecondarySettingsButton(title: "Copy Token", systemImage: "key") {
                        model.copyGatewayToken()
                    }
                }
            }

            SettingsCard(title: "Verified Usage", subtitle: "Current validated operational path.") {
                CodeBlock(value: "ANTHROPIC_BASE_URL=\(model.endpoint)\nANTHROPIC_AUTH_TOKEN=<gateway-token>\nclaude --bare -p --output-format json 'Reply exactly SMOKEOK.'")
            }
        }
    }
}

private struct UpstreamSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Subscription Runtime", subtitle: "These values define the ChatGPT/Codex-backed execution path.") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsTextField(title: "Responses URL", text: $model.responsesURLDraft)
                    SettingsTextField(title: "Executor Model", text: $model.executorModelDraft)
                    SettingsTextField(title: "Advisor Model", text: $model.advisorModelDraft)
                    SettingsTextField(title: "Subscription Auth File", text: $model.subscriptionAuthFilePathDraft)
                    SummaryLine(label: "Auth state", value: model.authText)
                }
            }

            SettingsCard(title: "Upstream Actions", subtitle: "Model and auth-file changes are saved to the local configuration.") {
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: "Save Upstream", systemImage: "tray.and.arrow.down") {
                        model.saveUpstreamSettings()
                    }
                    SecondarySettingsButton(title: "Reveal Auth File", systemImage: "person.badge.key") {
                        model.openSubscriptionAuthLocation()
                    }
                    SecondarySettingsButton(title: "Reload Config", systemImage: "arrow.clockwise.circle") {
                        model.reloadPersistedConfiguration()
                    }
                }
            }
        }
    }
}

private struct DiagnosticsSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Request Health", subtitle: "Recent runtime metrics derived from local trace telemetry.") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    CompactMetric(title: "Requests", value: "\(model.recentRequestCount)")
                    CompactMetric(title: "Success", value: "\(model.recentSuccessCount)")
                    CompactMetric(title: "Failure", value: "\(model.recentFailureCount)")
                    CompactMetric(title: "Error Rate", value: PercentFormatter.string(for: model.errorRate))
                    CompactMetric(title: "p50", value: model.p50LatencyMilliseconds.map { "\($0) ms" } ?? "n/a")
                    CompactMetric(title: "p95", value: model.p95LatencyMilliseconds.map { "\($0) ms" } ?? "n/a")
                }
                .frame(maxWidth: .infinity)
            }

            SettingsCard(title: "Connector Diagnostics", subtitle: "Recent stages, function calls, connector activity, and rejected paths.") {
                VStack(alignment: .leading, spacing: 10) {
                    SummaryLine(label: "Stages", value: formatStagePairs(model.traceStageCounts))
                    SummaryLine(label: "Function calls", value: joinedOrFallback(model.recentFunctionCallNames))
                    SummaryLine(label: "Connectors", value: joinedOrFallback(model.recentConnectorNames))
                    SummaryLine(label: "Rejected paths", value: joinedOrFallback(model.recentRejectedPaths))
                    SummaryLine(label: "Recent errors", value: joinedOrFallback(model.recentErrorReasons))
                }
            }

            SettingsCard(title: "Trace Access", subtitle: "Use these controls when runtime inspection moves beyond the dashboard.") {
                CodeBlock(value: model.tracePath)
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: "Copy Diagnostics", systemImage: "doc.text.magnifyingglass") {
                        model.copyDiagnosticsSummary()
                    }
                    SecondarySettingsButton(title: "Reveal Trace", systemImage: "text.append") {
                        model.openTraceLocation()
                    }
                }
            }

            SettingsCard(title: "Recent Events", subtitle: "Latest raw lines from the local trace feed.") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.recentTraceLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

private struct AdvancedSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "System Integration", subtitle: "Low-frequency system behaviors for packaged app usage.") {
                SummaryLine(label: "Launch at login", value: model.launchAtLoginText)
                HStack(spacing: 12) {
                    PrimarySettingsButton(title: model.launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login", systemImage: "power") {
                        model.toggleLaunchAtLogin()
                    }
                    SecondarySettingsButton(title: "Restart Daemon", systemImage: "arrow.clockwise") {
                        model.restartDaemon()
                    }
                }
            }

            SettingsCard(title: "Operational Notes", subtitle: "Current runtime guidance and warnings from the app.") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.doctorNotes, id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardPalette.settingsCard, in: RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardTokens.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodeBlock: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: DashboardTokens.smallCornerRadius, style: .continuous))
    }
}

private struct SummaryLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct CompactMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: DashboardTokens.smallCornerRadius, style: .continuous))
    }
}

private struct StatusBadge: View {
    let title: String
    let tone: DashboardTone

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tone.color.opacity(0.88), in: Capsule(style: .continuous))
    }
}

private struct KeyValuePill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DashboardPalette.mutedInk)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(DashboardPalette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let tone: DashboardTone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionButtonStyle(tone: tone))
    }
}

private struct ActionButtonStyle: ButtonStyle {
    let tone: DashboardTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tone.color.opacity(configuration.isPressed ? 0.55 : 0.82))
            )
            .foregroundStyle(Color.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct PrimarySettingsButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

private struct SecondarySettingsButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private struct PercentFormatter {
    static func string(for value: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, value)) * 100)
    }
}

private func formatStagePairs(_ values: [String: Int]) -> String {
    guard !values.isEmpty else { return "No recent stages" }
    return values.keys.sorted().map { key in
        "\(key)=\(values[key] ?? 0)"
    }
    .joined(separator: ", ")
}

private func joinedOrFallback(_ values: [String]) -> String {
    values.isEmpty ? "No recent activity" : values.joined(separator: ", ")
}
