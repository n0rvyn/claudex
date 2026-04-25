import AppKit
import Combine
import CCRouterCore
import SwiftUI

// MARK: - AppModel test-seam dependencies

protocol ConfigurationStoring {
    func loadOrCreate() -> RouterConfiguration
    @discardableResult
    func save(configuration: RouterConfiguration) -> RouterConfiguration
    func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration
}

extension RouterConfigurationStore: ConfigurationStoring {}

// MARK: - Routing Insight Row

/// One row in the Dashboard Routing insights section.
struct RoutingInsightRow: Equatable {
    let claudeModelKey: String
    let displayName: String
    let currentRouteLabel: String
    let metrics: ClaudeModelMetrics?
}

struct RoutingRuleDraft: Identifiable, Equatable {
    let id: UUID
    var keyword: String
    var upstreamModel: String
    var effort: String
    var verbosity: String

    init(
        id: UUID = UUID(),
        keyword: String,
        upstreamModel: String,
        effort: String,
        verbosity: String
    ) {
        self.id = id
        self.keyword = keyword
        self.upstreamModel = upstreamModel
        self.effort = effort
        self.verbosity = verbosity
    }
}

struct RouteDraft: Equatable {
    var upstreamModel: String
    var effort: String
    var verbosity: String
}

enum RoutingOptions {
    static let upstreamModels = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"]
    static let efforts = ["low", "medium", "high", "xhigh"]
    static let verbosities = ["low", "medium", "high"]
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var daemonState = "stopped"
    @Published private(set) var endpoint = "http://127.0.0.1:4317"
    @Published private(set) var statusText = "ModelBridge daemon stopped"
    @Published private(set) var authState: SubscriptionAuthState?
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
    @Published private(set) var recentRequestCount = 0
    @Published private(set) var recentSuccessCount = 0
    @Published private(set) var recentFailureCount = 0
    @Published private(set) var requestsPerMinute = 0.0
    @Published private(set) var lastRequestOutcome = "No recent request"
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var p50LatencyMilliseconds: Int?
    @Published private(set) var p95LatencyMilliseconds: Int?
    @Published private(set) var recentErrorReasons: [String] = []
    @Published private(set) var doctorSnapshot: DoctorSnapshot?
    @Published private(set) var launchAtLoginText = "Launch at login unknown"
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var currentConfiguration: RouterConfiguration

    @Published var gatewayHostDraft: String
    @Published var gatewayPortDraft: String
    @Published var responsesURLDraft: String
    @Published var subscriptionAuthFilePathDraft: String
    @Published var routingRulesDraft: [RoutingRuleDraft] = []
    @Published var fallbackRouteDraft: RouteDraft
    @Published var advisorRouteDraft: RouteDraft
    @Published var routingSaveError: String?
    @Published var isRefreshingToken = false
    @Published var tokenRefreshError: String?

    private let configurationStore: any ConfigurationStoring
    private let launchAtLoginController = LaunchAtLoginController()
    private var daemon: GatewayDaemon
    private var refreshCancellable: AnyCancellable?
    private var subscriptionAuthBookmarkDataDraft: Data?
    private let subscriptionRefresherFactory: @Sendable (URL, Data?) -> any SubscriptionSessionProviding
    private let routingUpdateApplier: (@Sendable (ModelRoutingTable, ModelRoute) async -> Void)?

    init(
        configurationStore: any ConfigurationStoring = RouterConfigurationStore(),
        subscriptionRefresherFactory: @escaping @Sendable (URL, Data?) -> any SubscriptionSessionProviding = { url, bookmark in
            SubscriptionSessionLoader(authFileURL: url, securityScopedBookmarkData: bookmark)
        },
        routingUpdateApplier: (@Sendable (ModelRoutingTable, ModelRoute) async -> Void)? = nil
    ) {
        self.configurationStore = configurationStore
        self.subscriptionRefresherFactory = subscriptionRefresherFactory
        self.routingUpdateApplier = routingUpdateApplier
        let configuration = configurationStore.loadOrCreate()
        self.currentConfiguration = configuration
        self.gatewayHostDraft = configuration.host
        self.gatewayPortDraft = String(configuration.port)
        self.responsesURLDraft = configuration.responsesURL
        self.subscriptionAuthFilePathDraft = configuration.subscriptionAuthFilePath
        self.fallbackRouteDraft = RouteDraft(
            upstreamModel: configuration.routingTable.fallback.upstreamModel,
            effort: configuration.routingTable.fallback.reasoningEffort,
            verbosity: configuration.routingTable.fallback.textVerbosity
        )
        self.advisorRouteDraft = RouteDraft(
            upstreamModel: configuration.advisorRoute.upstreamModel,
            effort: configuration.advisorRoute.reasoningEffort,
            verbosity: configuration.advisorRoute.textVerbosity
        )
        self.subscriptionAuthBookmarkDataDraft = configuration.subscriptionAuthBookmarkData
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

    // MARK: Derived state

    var daemonIsRunning: Bool { daemonState == "running" }

    var isUpstreamReady: Bool {
        authState?.isReady == true
    }

    var requiresAuthAttention: Bool {
        guard let authState else { return false }
        return !authState.isReady
    }

    var canStartDaemon: Bool {
        daemonIsRunning || isUpstreamReady
    }

    var primaryActionLabel: String {
        if daemonIsRunning { return "Pause" }
        switch authState {
        case .authorizationRequired?:
            return "Authorize"
        case .bookmarkResolutionFailed?:
            return "Reauthorize"
        case .ready?:
            return "Start"
        case .none:
            return "Checking"
        default:
            return "Fix auth"
        }
    }

    var primaryActionSystemImage: String {
        if daemonIsRunning { return "pause.fill" }
        switch authState {
        case .authorizationRequired?, .bookmarkResolutionFailed?:
            return "key.horizontal"
        case .ready?:
            return "play.fill"
        case .none:
            return "hourglass"
        default:
            return "exclamationmark.triangle"
        }
    }

    var authResolutionLabel: String {
        switch authState {
        case .authorizationRequired?:
            return "Authorize"
        case .bookmarkResolutionFailed?:
            return "Reauthorize"
        case .ready?:
            return "Authorized"
        case .none:
            return "Checking"
        default:
            return "Choose auth file"
        }
    }

    var authResolutionSystemImage: String {
        switch authState {
        case .authorizationRequired?, .bookmarkResolutionFailed?, .none:
            return "key.horizontal"
        case .ready?:
            return "checkmark.circle"
        default:
            return "folder.badge.questionmark"
        }
    }

    var authActionTitle: String {
        switch authState {
        case .authorizationRequired?:
            return "Authorize upstream auth"
        case .bookmarkResolutionFailed?:
            return "Reauthorize upstream auth"
        case .authFileMissing?:
            return "Auth file is missing"
        case .authFileUnreadable?:
            return "Auth file could not be read"
        case .authFileInvalid?:
            return "Auth file is invalid"
        case .missingAccessToken?:
            return "Auth file is missing access token"
        case .missingAccountID?:
            return "Auth file is missing account id"
        case .unknownFailure?:
            return "Auth check failed"
        case .ready?:
            return "Upstream auth ready"
        case .none:
            return "Checking upstream auth"
        }
    }

    var authInstructionText: String {
        "Click Authorize, then choose ~/.codex/auth.json from your home folder."
    }

    var headerDotState: MBDot.State {
        if authState == nil { return .idle }
        if requiresAuthAttention { return .warn }
        if !daemonIsRunning { return .idle }
        if !isUpstreamReady { return .warn }
        if recentFailureCount > 0 { return .warn }
        return .live
    }

    var headerStatusText: String {
        switch authState {
        case .none:
            return "Checking upstream auth"
        case .authorizationRequired?:
            return "Authorize auth file to enable gateway"
        case .bookmarkResolutionFailed?:
            return "Reauthorize auth file"
        case .authFileMissing?:
            return "Auth file missing"
        case .authFileUnreadable?:
            return "Auth file unreadable"
        case .authFileInvalid?:
            return "Auth file invalid"
        case .missingAccessToken?:
            return "Auth file missing access token"
        case .missingAccountID?:
            return "Auth file missing account id"
        case .unknownFailure?:
            return "Auth check failed"
        case .ready?:
            break
        }
        if !daemonIsRunning { return "Gateway paused" }
        if recentFailureCount > 0 { return "Gateway running · recent failures" }
        return "Gateway running"
    }

    var errorRate: Double {
        guard recentRequestCount > 0 else { return 0 }
        return Double(recentFailureCount) / Double(recentRequestCount)
    }

    var successRate: Double { 1 - errorRate }

    var endpointShortLabel: String {
        endpoint.replacingOccurrences(of: "http://", with: "")
    }

    var upstreamDisplayName: String {
        guard let host = URL(string: currentConfiguration.responsesURL)?.host else { return "Upstream" }
        if host.contains("chatgpt.com") { return "ChatGPT Codex" }
        if host.contains("anthropic.com") { return "Anthropic" }
        if host.contains("openai.com") { return "OpenAI" }
        return host
    }

    var upstreamHostLabel: String {
        URL(string: currentConfiguration.responsesURL)?.host ?? currentConfiguration.responsesURL
    }

    var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String
        let build = dict?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "v\(s) (\(b))"
        case let (s?, _):  return "v\(s)"
        case let (_, b?):  return "build \(b)"
        default:           return "dev"
        }
    }

    var formattedRequestsPerMinute: String {
        String(format: "%.1f", requestsPerMinute)
    }

    var latencySummary: String {
        let p50 = p50LatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
        let p95 = p95LatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
        return "\(p50) / \(p95)"
    }

    var routingInsights: [RoutingInsightRow] {
        let modelKeys: [(key: String, display: String)] = [
            ("opus", "Opus"),
            ("sonnet", "Sonnet"),
            ("haiku", "Haiku"),
        ]
        let metricsMap = doctorSnapshot?.traceDiagnostics.perClaudeModelMetrics ?? [:]
        return modelKeys.map { key, display in
            let resolved = currentConfiguration.routingTable.resolveWithMatch(for: "claude-\(key)-probe")
            let label = "\(resolved.route.upstreamModel) · \(resolved.route.reasoningEffort)"
            // Match full model name (e.g. "claude-opus-4-7") containing the keyword.
            let metrics = metricsMap.first { $0.key.lowercased().contains(key) }?.value
            return RoutingInsightRow(
                claudeModelKey: key,
                displayName: display,
                currentRouteLabel: label,
                metrics: metrics
            )
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

    // MARK: Actions

    func startDaemon() {
        guard canStartDaemon else {
            resolveAuthBlockingState(for: "starting the gateway")
            return
        }
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
            await refreshSnapshot(runningText: "ModelBridge daemon stopped")
        }
    }

    func toggleDaemon() {
        if daemonIsRunning {
            stopDaemon()
        } else {
            startDaemon()
        }
    }

    func restartDaemon() {
        guard canStartDaemon else {
            resolveAuthBlockingState(for: "restarting the gateway")
            return
        }
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
        guard isUpstreamReady else {
            resolveAuthBlockingState(for: "copying the Claude environment")
            return
        }
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

    func openConfigurationLocation() { revealPath(configurationPath) }
    func openSubscriptionAuthLocation() { revealPath(subscriptionAuthFilePath) }
    func openTraceLocation() { revealPath(tracePath) }

    func updateSubscriptionAuthFilePathDraft(_ path: String) {
        subscriptionAuthFilePathDraft = path
        if path != currentConfiguration.subscriptionAuthFilePath {
            subscriptionAuthBookmarkDataDraft = nil
        }
    }

    func chooseSubscriptionAuthFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        let suggestedURL = URL(
            fileURLWithPath: UserHomeResolver.defaultSubscriptionAuthFilePath()
        )
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        statusText = "Validating auth file authorization"
        Task {
            do {
                let bookmarkData = try selectedURL.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                _ = try await SubscriptionSessionLoader(
                    authFileURL: selectedURL,
                    securityScopedBookmarkData: bookmarkData
                ).loadCurrent()
                subscriptionAuthFilePathDraft = selectedURL.path
                subscriptionAuthBookmarkDataDraft = bookmarkData
                await persistSubscriptionAuthAuthorization(
                    path: selectedURL.path,
                    bookmarkData: bookmarkData
                )
            } catch {
                statusText = "Auth file authorization failed: \(error.localizedDescription)"
                syncDrafts(currentConfiguration)
                await refreshSnapshot(runningText: statusText)
            }
        }
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
        guard canPersistDraftAuthPath() else { return }
        persistConfiguration(
            host: gatewayHostDraft,
            port: port,
            responsesURL: responsesURLDraft,
            executorModel: currentConfiguration.executorModel,
            advisorModel: currentConfiguration.advisorModel,
            subscriptionAuthFilePath: subscriptionAuthFilePathDraft,
            subscriptionAuthBookmarkData: subscriptionAuthBookmarkDataDraft,
            statusMessage: "Gateway settings saved"
        )
    }

    func saveLegacyUpstreamSettings() {
        guard let port = Int(gatewayPortDraft), (1...65_535).contains(port) else {
            statusText = "Port must be between 1 and 65535"
            return
        }
        guard canPersistDraftAuthPath() else { return }
        persistConfiguration(
            host: gatewayHostDraft,
            port: port,
            responsesURL: responsesURLDraft,
            executorModel: currentConfiguration.executorModel,
            advisorModel: currentConfiguration.advisorModel,
            subscriptionAuthFilePath: subscriptionAuthFilePathDraft,
            subscriptionAuthBookmarkData: subscriptionAuthBookmarkDataDraft,
            statusMessage: "Upstream settings saved"
        )
    }

    func addRoutingRule() {
        routingRulesDraft.append(
            RoutingRuleDraft(keyword: "", upstreamModel: "gpt-5.4", effort: "xhigh", verbosity: "low")
        )
    }

    func removeRoutingRule(id: UUID) {
        routingRulesDraft.removeAll { $0.id == id }
    }

    func moveRoutingRule(from source: IndexSet, to destination: Int) {
        routingRulesDraft.move(fromOffsets: source, toOffset: destination)
    }

    func saveRoutingAndApply() async {
        guard let port = Int(gatewayPortDraft), (1...65_535).contains(port) else {
            routingSaveError = "Port must be between 1 and 65535"
            statusText = routingSaveError ?? statusText
            return
        }
        guard canPersistDraftAuthPath() else { return }

        let trimmedRules = routingRulesDraft.map { draft in
            RoutingRuleDraft(
                id: draft.id,
                keyword: draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                upstreamModel: draft.upstreamModel,
                effort: draft.effort,
                verbosity: draft.verbosity
            )
        }
        guard trimmedRules.allSatisfy({ !$0.keyword.isEmpty }) else {
            routingSaveError = "Routing rule keywords cannot be empty"
            statusText = routingSaveError ?? statusText
            return
        }

        routingSaveError = nil
        let table = ModelRoutingTable(
            rules: trimmedRules.map { draft in
                ModelRoutingRule(
                    match: draft.keyword,
                    route: ModelRoute(
                        upstreamModel: draft.upstreamModel,
                        reasoningEffort: draft.effort,
                        textVerbosity: draft.verbosity
                    )
                )
            },
            fallback: ModelRoute(
                upstreamModel: fallbackRouteDraft.upstreamModel,
                reasoningEffort: fallbackRouteDraft.effort,
                textVerbosity: fallbackRouteDraft.verbosity
            )
        )
        let advisor = ModelRoute(
            upstreamModel: advisorRouteDraft.upstreamModel,
            reasoningEffort: advisorRouteDraft.effort,
            textVerbosity: advisorRouteDraft.verbosity
        )

        let saved = configurationStore.save(
            configuration: RouterConfiguration(
                host: gatewayHostDraft,
                port: port,
                healthPath: currentConfiguration.healthPath,
                messagesPath: currentConfiguration.messagesPath,
                countTokensPath: currentConfiguration.countTokensPath,
                responsesURL: responsesURLDraft,
                routingTable: table,
                advisorRoute: advisor,
                pendingToolTurnTTLSeconds: currentConfiguration.pendingToolTurnTTLSeconds,
                advisorContextMessageLimit: currentConfiguration.advisorContextMessageLimit,
                gatewayAuthToken: currentConfiguration.gatewayAuthToken,
                gatewayAuthHeader: currentConfiguration.gatewayAuthHeader,
                subscriptionAuthFilePath: subscriptionAuthFilePathDraft,
                subscriptionAuthBookmarkData: subscriptionAuthBookmarkDataDraft,
                configurationPath: currentConfiguration.configurationPath,
                configurationWarning: currentConfiguration.configurationWarning
            )
        )
        currentConfiguration = saved
        applyConfigurationStatus(saved)
        syncDrafts(saved)
        if let routingUpdateApplier {
            await routingUpdateApplier(table, advisor)
        } else {
            await daemon.applyRoutingUpdate(table: table, advisorRoute: advisor)
        }
        await refreshSnapshot(runningText: "Routing and upstream settings saved")
    }

    func refreshTokenNow() async {
        guard !isRefreshingToken else { return }
        isRefreshingToken = true
        tokenRefreshError = nil
        defer { isRefreshingToken = false }

        do {
            let refresher = subscriptionRefresherFactory(
                URL(fileURLWithPath: currentConfiguration.subscriptionAuthFilePath),
                currentConfiguration.subscriptionAuthBookmarkData
            )
            _ = try await refresher.refreshAndReload()
            await refreshSnapshot(runningText: "Subscription token refreshed")
        } catch {
            tokenRefreshError = error.localizedDescription
            statusText = "Token refresh failed: \(error.localizedDescription)"
        }
    }

    func startTokenStatusPolling() async {
        while !Task.isCancelled {
            await refreshSnapshot(runningText: statusText)
            try? await Task.sleep(for: .seconds(30))
        }
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

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Private

    private func persistConfiguration(
        host: String,
        port: Int,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data?,
        statusMessage: String
    ) {
        Task {
            let wasRunning = daemonIsRunning
            // Update only the fallback upstream model + advisor upstream model from the UI drafts;
            // preserve existing routing rules so a Settings save does not wipe the defaultTable.
            let existingTable = currentConfiguration.routingTable
            let updatedTable = ModelRoutingTable(
                rules: existingTable.rules,
                fallback: ModelRoute(
                    upstreamModel: executorModel,
                    reasoningEffort: existingTable.fallback.reasoningEffort,
                    textVerbosity: existingTable.fallback.textVerbosity
                )
            )
            let existingAdvisor = currentConfiguration.advisorRoute
            let updatedAdvisor = ModelRoute(
                upstreamModel: advisorModel,
                reasoningEffort: existingAdvisor.reasoningEffort,
                textVerbosity: existingAdvisor.textVerbosity
            )
            let saved = configurationStore.save(
                configuration: RouterConfiguration(
                    host: host,
                    port: port,
                    healthPath: currentConfiguration.healthPath,
                    messagesPath: currentConfiguration.messagesPath,
                    countTokensPath: currentConfiguration.countTokensPath,
                    responsesURL: responsesURL,
                    routingTable: updatedTable,
                    advisorRoute: updatedAdvisor,
                    gatewayAuthToken: currentConfiguration.gatewayAuthToken,
                    gatewayAuthHeader: currentConfiguration.gatewayAuthHeader,
                    subscriptionAuthFilePath: subscriptionAuthFilePath,
                    subscriptionAuthBookmarkData: subscriptionAuthBookmarkData,
                    configurationPath: currentConfiguration.configurationPath,
                    configurationWarning: currentConfiguration.configurationWarning
                )
            )
            await replaceDaemon(with: saved, restartIfRunning: wasRunning)
            syncDrafts(saved)
            statusText = wasRunning ? "\(statusMessage); daemon restarted" : statusMessage
        }
    }

    private func persistSubscriptionAuthAuthorization(path: String, bookmarkData: Data) async {
        let wasRunning = daemonIsRunning
        // Auth-file authorization does not change routing; preserve the existing routingTable + advisorRoute.
        let saved = configurationStore.save(
            configuration: RouterConfiguration(
                host: currentConfiguration.host,
                port: currentConfiguration.port,
                healthPath: currentConfiguration.healthPath,
                messagesPath: currentConfiguration.messagesPath,
                countTokensPath: currentConfiguration.countTokensPath,
                responsesURL: currentConfiguration.responsesURL,
                routingTable: currentConfiguration.routingTable,
                advisorRoute: currentConfiguration.advisorRoute,
                gatewayAuthToken: currentConfiguration.gatewayAuthToken,
                gatewayAuthHeader: currentConfiguration.gatewayAuthHeader,
                subscriptionAuthFilePath: path,
                subscriptionAuthBookmarkData: bookmarkData,
                configurationPath: currentConfiguration.configurationPath,
                configurationWarning: currentConfiguration.configurationWarning
            )
        )
        await replaceDaemon(with: saved, restartIfRunning: wasRunning)
        syncDrafts(saved)
        statusText = wasRunning
            ? "Auth file authorized; daemon restarted"
            : "Auth file authorized"
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
        authState = snapshot.authState
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
        doctorSnapshot = snapshot
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
        subscriptionAuthFilePathDraft = configuration.subscriptionAuthFilePath
        subscriptionAuthBookmarkDataDraft = configuration.subscriptionAuthBookmarkData
        syncRoutingDraftsFromConfiguration(configuration)
    }

    func syncRoutingDraftsFromConfiguration(_ configuration: RouterConfiguration? = nil) {
        let configuration = configuration ?? currentConfiguration
        routingRulesDraft = configuration.routingTable.rules.map { rule in
            RoutingRuleDraft(
                keyword: rule.match,
                upstreamModel: rule.route.upstreamModel,
                effort: rule.route.reasoningEffort,
                verbosity: rule.route.textVerbosity
            )
        }
        fallbackRouteDraft = RouteDraft(
            upstreamModel: configuration.routingTable.fallback.upstreamModel,
            effort: configuration.routingTable.fallback.reasoningEffort,
            verbosity: configuration.routingTable.fallback.textVerbosity
        )
        advisorRouteDraft = RouteDraft(
            upstreamModel: configuration.advisorRoute.upstreamModel,
            effort: configuration.advisorRoute.reasoningEffort,
            verbosity: configuration.advisorRoute.textVerbosity
        )
    }

    private func makeDoctorNotes(configurationWarning: String?) -> [String] {
        var notes = [
            "Claude Code uses ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN from this app.",
            "ModelBridge forwards Anthropic Messages to chatgpt.com/backend-api/codex/responses.",
            "Ingress auth is enforced through x-api-key.",
            "Settings changes restart the daemon automatically when it is already running.",
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

    private func canPersistDraftAuthPath() -> Bool {
        let authPathChanged = subscriptionAuthFilePathDraft != currentConfiguration.subscriptionAuthFilePath
        if authPathChanged && subscriptionAuthBookmarkDataDraft == nil {
            statusText = "Use Choose to authorize the auth file before saving this path"
            return false
        }
        return true
    }

    private func resolveAuthBlockingState(for action: String) {
        guard let authState else {
            statusText = "Checking auth state before \(action)"
            refresh()
            return
        }
        switch authState {
        case .ready:
            return
        case .authorizationRequired, .bookmarkResolutionFailed,
             .authFileMissing, .authFileUnreadable, .authFileInvalid,
             .missingAccessToken, .missingAccountID:
            statusText = "Fix upstream auth before \(action)"
            chooseSubscriptionAuthFile()
        case .unknownFailure:
            statusText = "Resolve upstream auth failure before \(action)"
            refresh()
        }
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
        case "initial":                return "Last request completed"
        case "advisor_or_tools":       return "Tool or advisor path active"
        case "continuation":           return "Continuation completed"
        case "responses_http_error":   return "Upstream HTTP error"
        case "subscription_error":     return "Subscription auth error"
        case "decode_or_bridge_error": return "Gateway request error"
        case "auth_rejected":          return "Local auth rejected"
        case nil:                      return "No recent request"
        default:                       return outcome ?? "No recent request"
        }
    }
}

// MARK: - Menu bar popover (ContentView)

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .overlay(Divider().frame(height: 0.5), alignment: .bottom)

            bridgeSection
                .padding(.horizontal, 14)
                .padding(.top, 12)

            if model.requiresAuthAttention {
                authActionSection
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            kpiSection
                .padding(.horizontal, 12)
                .padding(.top, 10)

            recentSection
                .padding(.horizontal, 12)
                .padding(.top, 12)

            routingInsightsSection
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)

            footerSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(MBColor.paperDim)
                .overlay(Divider().frame(height: 0.5), alignment: .top)
        }
        .frame(width: 380)
        .background(MBColor.paper)
    }

    // MARK: Sections

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            MBBridgeBadge(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Bridge")
                    .font(MBFont.title)
                    .foregroundStyle(MBColor.ink)
                HStack(spacing: 6) {
                    MBDot(state: model.headerDotState, size: 6)
                    Text(model.headerStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(MBColor.inkDim)
                        .lineLimit(1)
                    Text("·").foregroundStyle(MBColor.inkFaint)
                    Text(model.appVersion)
                        .font(MBFont.monoSmall)
                        .foregroundStyle(MBColor.inkDim)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { model.daemonIsRunning },
                set: { _ in model.toggleDaemon() }
            ))
            .toggleStyle(MBToggleStyle())
            .labelsHidden()
            .fixedSize()
            .disabled(!model.canStartDaemon)
        }
    }

    private var bridgeSection: some View {
        MBCard(padding: 10) {
            HStack(spacing: 10) {
                clientCell
                MBFlowLine(running: model.daemonIsRunning, color: MBColor.live)
                    .frame(maxWidth: .infinity)
                upstreamCell
            }
        }
    }

    private var clientCell: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(model.daemonIsRunning ? MBColor.live : MBColor.inkFaint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MBColor.ink)
                Text(model.endpointShortLabel)
                    .font(MBFont.monoSmall)
                    .foregroundStyle(MBColor.inkDim)
            }
        }
        .frame(width: 132, alignment: .leading)
    }

    private var upstreamCell: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            MBPill(text: model.upstreamDisplayName, tone: .neutral)
        }
        .frame(maxWidth: 120)
    }

    private var kpiSection: some View {
        MBCard(padding: 12, background: MBColor.paperDim) {
            HStack(alignment: .top, spacing: 14) {
                MBKpi(
                    label: "Requests",
                    value: "\(model.recentRequestCount)",
                    detail: "\(model.formattedRequestsPerMinute) / min"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(MBColor.ruleSoft).frame(width: 0.5)

                MBKpi(
                    label: "Success",
                    value: model.recentRequestCount == 0 ? "—" : percentString(model.successRate),
                    detail: model.recentRequestCount == 0
                        ? MBCopy.trafficEmptyShort
                        : "\(model.recentSuccessCount) ok · \(model.recentFailureCount) err",
                    tone: model.recentFailureCount > 0 ? .warn : .live
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(MBColor.ruleSoft).frame(width: 0.5)

                MBKpi(
                    label: "Latency",
                    value: lastLatencyDisplay,
                    detail: latencyDetail
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var authActionSection: some View {
        MBCard(padding: 12, background: MBColor.paperDim) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MBColor.brand)
                    Text(model.authActionTitle)
                        .font(MBFont.labelB)
                        .foregroundStyle(MBColor.ink)
                }
                Text(model.authText)
                    .font(.system(size: 11))
                    .foregroundStyle(MBColor.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.authInstructionText)
                    .font(.system(size: 11))
                    .foregroundStyle(MBColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: { model.chooseSubscriptionAuthFile() }) {
                        Label(model.authResolutionLabel, systemImage: model.authResolutionSystemImage)
                    }
                    .buttonStyle(.borderedProminent)
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MBColor.brand)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MBSectionHeader(
                title: "Recent activity",
                trailing: AnyView(
                    Button(action: { model.openTraceLocation() }) {
                        HStack(spacing: 3) {
                            Text("Open trace")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MBColor.brand)
                )
            )
            .padding(.horizontal, 4)

            MBCard(padding: 0) {
                VStack(spacing: 0) {
                    if recentLines.isEmpty {
                        Text(MBCopy.trafficEmptyLong)
                            .font(.system(size: 11))
                            .foregroundStyle(MBColor.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(Array(recentLines.enumerated()), id: \.offset) { index, line in
                            let summary = TraceLineFormatter.summary(line)
                            HStack(spacing: 8) {
                                MBDot(state: summary.toneForStatus, size: 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(summary.message)
                                        .font(MBFont.mono)
                                        .foregroundStyle(MBColor.ink)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if let ts = summary.timestamp {
                                        Text(ts)
                                            .font(MBFont.monoSmall)
                                            .foregroundStyle(MBColor.inkDim)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let code = summary.statusCode {
                                    Text("\(code)")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(code >= 400 ? MBColor.faultInk : MBColor.inkDim)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(code >= 400 ? MBColor.faultSoft : MBColor.paperDim)
                                        )
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            if index < recentLines.count - 1 {
                                Rectangle().fill(MBColor.ruleSoft).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private var routingInsightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MBSectionHeader(title: "Routing insights")
                .padding(.horizontal, 4)

            MBCard(padding: 10, background: MBColor.paperDim) {
                VStack(spacing: 0) {
                    ForEach(Array(model.routingInsights.enumerated()), id: \.element.claudeModelKey) { index, row in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MBColor.ink)
                                Text("→ \(row.currentRouteLabel)")
                                    .font(MBFont.monoSmall)
                                    .foregroundStyle(MBColor.inkDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(routingInsightMetricText(row.metrics))
                                .font(MBFont.monoSmall)
                                .foregroundStyle(row.metrics == nil ? MBColor.inkFaint : MBColor.inkMid)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        if index < model.routingInsights.count - 1 {
                            Rectangle().fill(MBColor.ruleSoft).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack(spacing: 6) {
            FooterButton(
                systemImage: model.primaryActionSystemImage,
                label: model.primaryActionLabel,
                action: {
                    if model.daemonIsRunning {
                        model.toggleDaemon()
                    } else if model.isUpstreamReady {
                        model.toggleDaemon()
                    } else {
                        model.chooseSubscriptionAuthFile()
                    }
                },
                isDisabled: model.authState == nil
            )
            FooterButton(
                systemImage: "doc.on.doc",
                label: "Copy env",
                action: { model.copyEnvSnippet() },
                isDisabled: !model.isUpstreamReady
            )
            Spacer(minLength: 0)
            SettingsLink {
                FooterButtonLabel(systemImage: "gearshape", label: "Settings")
            }
            .buttonStyle(.plain)
            FooterButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                label: "Quit",
                action: { model.quit() }
            )
        }
    }

    // MARK: Helpers

    private var recentLines: [String] {
        Array(model.recentTraceLines.suffix(5).reversed())
    }

    private var lastLatencyDisplay: String {
        if let last = model.lastLatencyMilliseconds { return "\(last) ms" }
        if let p50 = model.p50LatencyMilliseconds { return "\(p50) ms" }
        return "—"
    }

    private var latencyDetail: String {
        if let p95 = model.p95LatencyMilliseconds { return "p95 \(p95) ms" }
        if let p50 = model.p50LatencyMilliseconds { return "p50 \(p50) ms" }
        return "No samples"
    }

    private func percentString(_ value: Double) -> String {
        let bounded = max(0, min(1, value))
        return String(format: "%.0f%%", bounded * 100)
    }

    private func routingInsightMetricText(_ metrics: ClaudeModelMetrics?) -> String {
        guard let metrics else { return "—" }
        let latency = metrics.p50LatencyMilliseconds.map { "\($0) ms" } ?? "—"
        return "\(metrics.requestCount) req · \(latency)"
    }
}

// MARK: - Footer button

private struct FooterButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    var isDisabled = false

    var body: some View {
        Button(action: action) {
            FooterButtonLabel(systemImage: systemImage, label: label)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

private struct FooterButtonLabel: View {
    let systemImage: String
    let label: String

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(MBColor.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? MBColor.paperAlt : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(hovered ? MBColor.rule : Color.clear, lineWidth: 0.5)
        )
        .onHover { hovered = $0 }
    }
}
