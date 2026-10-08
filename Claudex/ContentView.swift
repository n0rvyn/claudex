import AppKit
import Combine
import CCRouterCore
import ServiceManagement
import SwiftUI

// MARK: - AppModel test-seam dependencies

protocol ConfigurationStoring {
    func loadOrCreate() -> RouterConfiguration
    @discardableResult
    func save(configuration: RouterConfiguration) -> RouterConfiguration
    func saveVerified(configuration: RouterConfiguration) throws -> RouterConfiguration
    func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration
}

extension ConfigurationStoring {
    func saveVerified(configuration: RouterConfiguration) throws -> RouterConfiguration {
        let saved = save(configuration: configuration)
        guard loadOrCreate().routingTable == saved.routingTable else {
            throw NSError(domain: "Claudex.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Settings could not be saved. Your last saved mapping remains active."])
        }
        return saved
    }
}

extension RouterConfigurationStore: ConfigurationStoring {
    func saveVerified(configuration: RouterConfiguration) throws -> RouterConfiguration { try saveChecked(configuration: configuration) }
}

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
    static let verbosities = ["low", "medium", "high"]
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var daemonState = "stopped"
    @Published private(set) var endpoint = "http://127.0.0.1:4317"
    @Published private(set) var statusText = "Claudex daemon stopped"
    @Published private(set) var authState: SubscriptionAuthState?
    @Published private(set) var authText = "Auth unknown"
    @Published private(set) var gatewayTokenText = "Token unknown"
    @Published private(set) var configurationPath = ""
    @Published private(set) var configurationWarning: String?
    @Published private(set) var subscriptionAuthFilePath = ""
    @Published private(set) var envSnippet = ""
    @Published private(set) var connectionCheckCommand = ""
    @Published private(set) var tracePath = UserHomeResolver.defaultTraceLogFilePath()
    @Published private(set) var recentTraceLines: [String] = []
    @Published private(set) var doctorNotes: [String] = []
    @Published private(set) var traceStageCounts: [String: Int] = [:]
    @Published private(set) var recentFunctionCallNames: [String] = []
    @Published private(set) var recentConnectorNames: [String] = []
    @Published private(set) var recentRejectedPaths: [String] = []
    @Published private(set) var activeRequestCount: Int?
    @Published private(set) var traffic: SIWCTrafficSnapshot?
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
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var currentConfiguration: RouterConfiguration

    @Published var gatewayHostDraft: String
    @Published var gatewayPortDraft: String
    @Published var responsesURLDraft: String
    @Published var subscriptionAuthFilePathDraft: String
    @Published var routingRulesDraft: [RoutingRuleDraft] = []
    @Published var fableRouteDraft: RouteDraft
    @Published var fallbackRouteDraft: RouteDraft
    @Published var settingsTab: SettingsTab = .upstream
    @Published var advisorRouteDraft: RouteDraft
    @Published var useAdvancedRouting = false
    @Published var allowClaudeAdjustment = false
    @Published var showConnectionInstructions = false
    @Published var routingSaveError: String?
    @Published private(set) var mappingSaveStatus = "Changes save automatically"
    private var mappingSaveTask: Task<Void, Never>?
    private var mappingEditGeneration = 0
    private var mappingAutosaveSubscriptions: Set<AnyCancellable> = []
    private var isSyncingRoutingDrafts = false
    @Published var isRefreshingToken = false
    @Published var tokenRefreshError: String?

    private let offlinePreview: Bool
    private let configurationStore: any ConfigurationStoring
    private let launchAtLoginController = LaunchAtLoginController()
    private var daemon: GatewayDaemon
    private var refreshCancellable: AnyCancellable?
    private var subscriptionAuthBookmarkDataDraft: Data?
    private let subscriptionRefresherFactory: @Sendable (URL, Data?) -> any SubscriptionSessionProviding
    private let modelCatalog: SIWCModelCatalog
    private var modelCatalogLease = UUID()
    private var catalogAccountID: String?
    private let routingUpdateApplier: (@Sendable (ModelRoutingTable, ModelRoute) async -> Void)?

    init(
        configurationStore: any ConfigurationStoring = RouterConfigurationStore(),
        subscriptionRefresherFactory: @escaping @Sendable (URL, Data?) -> any SubscriptionSessionProviding = { url, bookmark in
            SIWCAuth.shared
        },
        routingUpdateApplier: (@Sendable (ModelRoutingTable, ModelRoute) async -> Void)? = nil,
        modelCatalog: SIWCModelCatalog = SIWCModelCatalog(),
        automaticallyLoadCatalog: Bool = true,
        offlinePreview: Bool = false
    ) {
        self.offlinePreview = offlinePreview
        self.configurationStore = configurationStore
        self.modelCatalog = modelCatalog
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
        self.fableRouteDraft = RouteDraft(upstreamModel: configuration.routingTable.effectiveFableRoute.upstreamModel, effort: configuration.routingTable.effectiveFableRoute.reasoningEffort, verbosity: configuration.routingTable.effectiveFableRoute.textVerbosity)
        self.advisorRouteDraft = RouteDraft(
            upstreamModel: configuration.advisorRoute.upstreamModel,
            effort: configuration.advisorRoute.reasoningEffort,
            verbosity: configuration.advisorRoute.textVerbosity
        )
        self.subscriptionAuthBookmarkDataDraft = configuration.subscriptionAuthBookmarkData
        self.daemon = GatewayDaemon(configuration: configuration, auth: subscriptionRefresherFactory(URL(fileURLWithPath: configuration.subscriptionAuthFilePath), configuration.subscriptionAuthBookmarkData))
        applyConfigurationStatus(configuration)
        syncDrafts(configuration)
        if offlinePreview { return }
        refreshLaunchAtLogin()
        if automaticallyLoadCatalog { Task { await loadChatGPTAccounts() } }
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
        daemonIsRunning || (isUpstreamReady && savedRoutingCatalogError == nil)
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
            return "Continue with ChatGPT"
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
        "Continue with ChatGPT to authorize Claudex. Existing Codex credentials are not imported."
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
        let completed = recentSuccessCount + recentFailureCount
        guard completed > 0 else { return 0 }
        return Double(recentFailureCount) / Double(completed)
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
            if isUpstreamReady { statusText = savedRoutingCatalogError ?? "Refresh models before starting" }
            else { resolveAuthBlockingState(for: "starting the gateway") }
            return
        }
        if offlinePreview { daemonState = "running"; statusText = "Gateway running"; showConnectionInstructions = true; return }
        Task {
            do {
                try await daemon.start()
                await refreshSnapshot(runningText: "Gateway running")
                showConnectionInstructions = true
            } catch {
                statusText = "Failed to start daemon: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        if offlinePreview { daemonState = "stopped"; statusText = "Gateway paused"; return }
        Task {
            await daemon.stop()
            await refreshSnapshot(runningText: "Claudex daemon stopped")
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
        guard !offlinePreview else { return }
        guard canStartDaemon else {
            resolveAuthBlockingState(for: "restarting the gateway")
            return
        }
        Task {
            await daemon.stop()
            daemon = GatewayDaemon(configuration: currentConfiguration, auth: subscriptionRefresherFactory(URL(fileURLWithPath: currentConfiguration.subscriptionAuthFilePath), currentConfiguration.subscriptionAuthBookmarkData))
            do {
                try await daemon.start()
                await refreshSnapshot(runningText: "Claudex daemon restarted")
            } catch {
                statusText = "Failed to restart daemon: \(error.localizedDescription)"
            }
        }
    }

    func refresh() {
        guard !offlinePreview else { return }
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

    @Published var modelCatalogSnapshot: SIWCModelCatalogSnapshot?
    @Published var availableChatGPTModels: [SIWCModelSummary] = []
    @Published var modelCatalogError: String?
    @Published var isLoadingModelCatalog = false
    @Published var chatGPTAccounts: [SIWCAccountSummary] = []
    @Published var signInError: String?
    @Published var isSigningIn = false
    private let chatGPTSignIn = SIWCSignIn()

    func beginChatGPTSignIn(accountID: String? = nil) {
        if offlinePreview { isSigningIn = true; signInError = nil; return }
        isSigningIn = true; signInError = nil
        chatGPTSignIn.onCompletion = { [weak self] result in
            guard let self else { return }
            self.isSigningIn = false
            if case .failure(let error) = result { self.signInError = error.localizedDescription }
            let succeeded = (try? result.get()) != nil
            Task { await self.loadChatGPTAccounts(forceCatalogRefresh: succeeded); self.refresh() }
        }
        Task {
            do {
                let url = try await chatGPTSignIn.start(accountID: accountID)
                guard NSWorkspace.shared.open(url) else { throw SIWCError.remote("browser_unavailable") }
            } catch {
                await chatGPTSignIn.cancel(); isSigningIn = false; signInError = error.localizedDescription
            }
        }
    }
    func cancelChatGPTSignIn() {
        if offlinePreview { isSigningIn = false; return }
        Task { await chatGPTSignIn.cancel(); isSigningIn = false }
    }
    var modelCatalogUsable: Bool {
        guard let snapshot = modelCatalogSnapshot,
              snapshot.accountID == chatGPTAccounts.first(where: { $0.active && $0.authorized })?.id,
              snapshot.isFresh(), modelCatalogError == nil else { return false }
        return true
    }
    var modelCatalogStatus: String {
        if isLoadingModelCatalog { return "Updating account models…" }
        if let error = modelCatalogError { return "Models unavailable: " + error }
        guard let snapshot = modelCatalogSnapshot else { return "Sign in or refresh the account model list." }
        let stamp = snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        return modelCatalogUsable ? "Account models · updated " + stamp + " · cache valid for 1 hour"
            : "Model list expired · last updated " + stamp + " · refresh required"
    }
    func routingCatalogError(_ routes: [ModelRoute]) -> String? {
        guard modelCatalogUsable, let snapshot = modelCatalogSnapshot else { return "Refresh the selected account's model list before saving or starting the gateway." }
        return routes.compactMap { snapshot.validationError(for: $0) }.first
    }
    var savedRoutingCatalogError: String? {
        routingCatalogError((currentConfiguration.routingTable.singleModelMode == true ? [] : currentConfiguration.routingTable.rules.map(\.route)) + [currentConfiguration.routingTable.fallback])
    }
    func loadChatGPTModelCatalog(force: Bool = true) async {
        guard let expectedAccount = chatGPTAccounts.first(where: { $0.active && $0.authorized })?.id,
              !isLoadingModelCatalog else { return }
        let lease = UUID(); modelCatalogLease = lease
        isLoadingModelCatalog = true
        defer { if modelCatalogLease == lease { isLoadingModelCatalog = false } }
        do {
            let snapshot = try await modelCatalog.load(accountID: expectedAccount, force: force)
            guard modelCatalogLease == lease,
                  chatGPTAccounts.first(where: { $0.active && $0.authorized })?.id == expectedAccount else { return }
            modelCatalogSnapshot = snapshot; availableChatGPTModels = snapshot.models; modelCatalogError = nil
        } catch {
            guard modelCatalogLease == lease else { return }
            availableChatGPTModels = []; modelCatalogSnapshot = nil; modelCatalogError = error.localizedDescription
        }
    }
    func loadChatGPTAccounts(forceCatalogRefresh: Bool = false) async {
        guard !offlinePreview else { return }
        do {
            let accounts = try await SIWCAuth.shared.accounts()
            chatGPTAccounts = accounts
            let active = accounts.first(where: { $0.active && $0.authorized })?.id
            if catalogAccountID != active {
                catalogAccountID = active; modelCatalogLease = UUID(); isLoadingModelCatalog = false
                availableChatGPTModels = []; modelCatalogSnapshot = nil; modelCatalogError = nil
                if daemonIsRunning { await daemon.stop(); await refreshSnapshot(runningText: "Gateway paused after account change") }
                if active != nil { await loadChatGPTModelCatalog(force: forceCatalogRefresh) }
            } else if forceCatalogRefresh { await loadChatGPTModelCatalog(force: true) }
        } catch {
            chatGPTAccounts = []; availableChatGPTModels = []; modelCatalogSnapshot = nil
            modelCatalogLease = UUID(); isLoadingModelCatalog = false; catalogAccountID = nil
            signInError = error.localizedDescription; modelCatalogError = error.localizedDescription
        }
    }
    func selectChatGPTAccount(_ id: String) {
        mappingSaveTask?.cancel(); mappingEditGeneration += 1
        mappingSaveStatus = "Refresh models for the selected account before editing"
        if offlinePreview { daemonState = "stopped"; modelCatalogSnapshot = nil; availableChatGPTModels = []; modelCatalogError = "Account changed. Refresh models to continue."; return }
        Task {
            do { try await SIWCAuth.shared.select(id); await loadChatGPTAccounts(forceCatalogRefresh: true); refresh() }
            catch { signInError = error.localizedDescription }
        }
    }
    func signOutChatGPT(_ id: String) {
        if offlinePreview { chatGPTAccounts = []; authState = .authorizationRequired; modelCatalogSnapshot = nil; availableChatGPTModels = []; daemonState = "stopped"; return }
        Task {
            do {
                let revoked = try await SIWCAuth.shared.signOut(id)
                signInError = revoked ? nil : "Signed out locally. Remote revocation was not confirmed; disconnect Claudex in ChatGPT Settings."
                await loadChatGPTAccounts(); refresh()
            } catch { signInError = error.localizedDescription }
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
            RoutingRuleDraft(keyword: "", upstreamModel: fallbackRouteDraft.upstreamModel, effort: fallbackRouteDraft.effort, verbosity: fallbackRouteDraft.verbosity)
        )
    }

    func removeRoutingRule(id: UUID) {
        routingRulesDraft.removeAll { $0.id == id }
    }

    func moveRoutingRule(from source: IndexSet, to destination: Int) {
        routingRulesDraft.move(fromOffsets: source, toOffset: destination)
    }

    func enableMappingAutosave() {
        guard mappingAutosaveSubscriptions.isEmpty else { return }
        Publishers.MergeMany([
            $routingRulesDraft.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $fableRouteDraft.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $fallbackRouteDraft.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $advisorRouteDraft.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $useAdvancedRouting.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $allowClaudeAdjustment.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in
            guard let self, !self.isSyncingRoutingDrafts else { return }
            self.scheduleMappingSave()
        }.store(in: &mappingAutosaveSubscriptions)
    }

    func scheduleMappingSave() {
        mappingEditGeneration += 1
        let generation = mappingEditGeneration
        mappingSaveTask?.cancel()
        mappingSaveStatus = "Saving…"
        mappingSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, generation == self.mappingEditGeneration else { return }
            await self.saveRoutingAndApply(syncSavedDrafts: false, onlyRouting: true)
            guard generation == self.mappingEditGeneration else { return }
            self.mappingSaveStatus = self.routingSaveError == nil ? "Saved" : "Not saved · last saved mapping remains active"
        }
    }

    func saveRoutingAndApply(syncSavedDrafts: Bool = true, onlyRouting: Bool = false) async {
        guard let port = onlyRouting ? currentConfiguration.port : Int(gatewayPortDraft), (1...65_535).contains(port) else {
            routingSaveError = "Port must be between 1 and 65535"
            statusText = routingSaveError ?? statusText
            return
        }
        guard onlyRouting || canPersistDraftAuthPath() else { return }

        let trimmedRules = routingRulesDraft.map { draft in
            RoutingRuleDraft(
                id: draft.id,
                keyword: draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                upstreamModel: draft.upstreamModel,
                effort: draft.effort,
                verbosity: draft.verbosity
            )
        }
        guard !useAdvancedRouting || trimmedRules.allSatisfy({ !$0.keyword.isEmpty }) else {
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
            ),
            singleModelMode: !useAdvancedRouting,
            allowClientEffort: allowClaudeAdjustment,
            fableRoute: ModelRoute(upstreamModel: fableRouteDraft.upstreamModel, reasoningEffort: fableRouteDraft.effort, textVerbosity: fableRouteDraft.verbosity)
        )
        let advisor = ModelRoute(
            upstreamModel: advisorRouteDraft.upstreamModel,
            reasoningEffort: advisorRouteDraft.effort,
            textVerbosity: advisorRouteDraft.verbosity
        )
        if let error = routingCatalogError((useAdvancedRouting ? table.rules.map(\.route) + [table.effectiveFableRoute] : []) + [table.fallback] + (advisor == currentConfiguration.advisorRoute ? [] : [advisor])) {
            routingSaveError = error; statusText = error; return
        }

        let saved: RouterConfiguration
        do { saved = try configurationStore.saveVerified(
            configuration: RouterConfiguration(
                host: onlyRouting ? currentConfiguration.host : gatewayHostDraft,
                port: port,
                healthPath: currentConfiguration.healthPath,
                messagesPath: currentConfiguration.messagesPath,
                countTokensPath: currentConfiguration.countTokensPath,
                responsesURL: onlyRouting ? currentConfiguration.responsesURL : responsesURLDraft,
                routingTable: table,
                advisorRoute: advisor,
                pendingToolTurnTTLSeconds: currentConfiguration.pendingToolTurnTTLSeconds,
                advisorContextMessageLimit: currentConfiguration.advisorContextMessageLimit,
                gatewayAuthToken: currentConfiguration.gatewayAuthToken,
                gatewayAuthHeader: currentConfiguration.gatewayAuthHeader,
                subscriptionAuthFilePath: onlyRouting ? currentConfiguration.subscriptionAuthFilePath : subscriptionAuthFilePathDraft,
                subscriptionAuthBookmarkData: onlyRouting ? currentConfiguration.subscriptionAuthBookmarkData : subscriptionAuthBookmarkDataDraft,
                configurationPath: currentConfiguration.configurationPath,
                configurationWarning: currentConfiguration.configurationWarning
            )
        )
        } catch {
            routingSaveError = error.localizedDescription
            return
        }
        currentConfiguration = saved
        applyConfigurationStatus(saved)
        if syncSavedDrafts { syncDrafts(saved) }
        if let routingUpdateApplier {
            await routingUpdateApplier(table, advisor)
        } else if !offlinePreview {
            await daemon.applyRoutingUpdate(table: table, advisorRoute: advisor)
        }
        await refreshSnapshot(runningText: "Routing and upstream settings saved")
    }

    func refreshTokenNow() async {
        guard !offlinePreview else { return }
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
        guard !offlinePreview else { return }
        while !Task.isCancelled {
            await refreshSnapshot(runningText: statusText)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func regenerateGatewayToken() {
        guard !offlinePreview else { return }
        Task {
            let wasRunning = daemonIsRunning
            let saved = configurationStore.regenerateGatewayToken(from: currentConfiguration)
            await replaceDaemon(with: saved, restartIfRunning: wasRunning)
            syncDrafts(saved)
            statusText = "Gateway token regenerated"
        }
    }

    func reloadPersistedConfiguration() {
        mappingSaveTask?.cancel(); mappingEditGeneration += 1
        mappingSaveStatus = "Restored saved mapping"; routingSaveError = nil
        let configuration = configurationStore.loadOrCreate()
        currentConfiguration = configuration
        applyConfigurationStatus(configuration)
        syncDrafts(configuration)
        if !offlinePreview { refreshLaunchAtLogin() }
        statusText = "Configuration reloaded"
        refresh()
    }

    func toggleLaunchAtLogin() {
        guard !offlinePreview else { return }
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
                ),
                singleModelMode: existingTable.singleModelMode,
                allowClientEffort: existingTable.allowClientEffort,
                fableRoute: existingTable.fableRoute
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
        daemon = GatewayDaemon(configuration: configuration, auth: subscriptionRefresherFactory(URL(fileURLWithPath: configuration.subscriptionAuthFilePath), configuration.subscriptionAuthBookmarkData))
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
        guard !offlinePreview else { return }
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
        gatewayTokenText = "Configured · hidden"
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
        activeRequestCount = snapshot.pendingToolTurnsCount
        traffic = snapshot.traffic
        if let traffic {
            recentRequestCount = traffic.requests
            recentSuccessCount = traffic.successes
            recentFailureCount = traffic.errors
            lastRequestOutcome = traffic.lastOutcome ?? "No completed request"
            p50LatencyMilliseconds = traffic.p50LatencyMilliseconds
            p95LatencyMilliseconds = traffic.p95LatencyMilliseconds
            requestsPerMinute = Double(traffic.requests) / 5
            lastLatencyMilliseconds = traffic.lastLatencyMilliseconds
            recentErrorReasons = traffic.lastError.map { [$0] } ?? []
        }
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
        connectionCheckCommand = configuration.claudeConnectionCheckCommand
        configurationPath = configuration.configurationPath
        configurationWarning = configuration.configurationWarning
        subscriptionAuthFilePath = configuration.subscriptionAuthFilePath
        gatewayTokenText = "Configured · hidden"
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
        isSyncingRoutingDrafts = true
        defer { isSyncingRoutingDrafts = false }
        allowClaudeAdjustment = configuration.routingTable.allowClientEffort == true
        useAdvancedRouting = configuration.routingTable.singleModelMode.map { !$0 } ?? true
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
        fableRouteDraft = RouteDraft(upstreamModel: configuration.routingTable.effectiveFableRoute.upstreamModel, effort: configuration.routingTable.effectiveFableRoute.reasoningEffort, verbosity: configuration.routingTable.effectiveFableRoute.textVerbosity)
        advisorRouteDraft = RouteDraft(
            upstreamModel: configuration.advisorRoute.upstreamModel,
            effort: configuration.advisorRoute.reasoningEffort,
            verbosity: configuration.advisorRoute.textVerbosity
        )
    }

    func prepareClaudeModelRows() {
        for keyword in ["opus", "sonnet", "haiku"] where !routingRulesDraft.contains(where: { $0.keyword.lowercased() == keyword }) {
            routingRulesDraft.append(RoutingRuleDraft(keyword: keyword, upstreamModel: fallbackRouteDraft.upstreamModel, effort: fallbackRouteDraft.effort, verbosity: fallbackRouteDraft.verbosity))
        }
    }

    var hasFableOverrides: Bool {
        routingRulesDraft.contains { rule in ["fable", "claude-fable-5", "claude-fable-5-1"].contains { $0.contains(rule.keyword.lowercased()) } }
    }

    var hasCustomRoutingRules: Bool {
        routingRulesDraft.contains { !["opus", "sonnet", "haiku"].contains($0.keyword.lowercased()) } ||
        ["opus", "sonnet", "haiku"].contains { keyword in routingRulesDraft.filter { $0.keyword.lowercased() == keyword }.count > 1 }
    }

    private func makeDoctorNotes(configurationWarning: String?) -> [String] {
        var notes = [
            "Claude Code uses ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN from this app.",
            "Claudex forwards Anthropic Messages to api.openai.com/v1/responses.",
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
        launchAtLoginStatus = launchAtLoginController.status
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
            beginChatGPTSignIn()
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

#if DEBUG
private final class PreviewConfigurationStore: ConfigurationStoring {
    var value: RouterConfiguration
    init(_ value: RouterConfiguration) { self.value = value }
    func loadOrCreate() -> RouterConfiguration { value }
    func save(configuration: RouterConfiguration) -> RouterConfiguration { value = configuration; return value }
    func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration { configuration }
}

extension AppModel {
    static func visualFixture(_ state: String, traffic: SIWCTrafficSnapshot? = nil, storeFactory: ((RouterConfiguration) -> any ConfigurationStoring)? = nil) -> AppModel {
        let route = ModelRoute(upstreamModel: state == "retired" ? "retired-model" : "gpt-6-luna", reasoningEffort: state == "unsupported" ? "ultra" : "low", textVerbosity: "low")
        let config = RouterConfiguration(host: "127.0.0.1", port: 4317, healthPath: "/health", messagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens", responsesURL: "https://api.openai.com/v1/responses", routingTable: ModelRoutingTable(rules: [], fallback: route, singleModelMode: false), advisorRoute: route, gatewayAuthToken: "fixture-only-not-a-credential", gatewayAuthHeader: "x-mb-token", subscriptionAuthFilePath: "/tmp/claudex-ui/fixture-auth-unused", configurationPath: "/tmp/claudex-ui/fixture-config-unused", configurationWarning: nil)
        let catalog = SIWCModelCatalog(directory: URL(fileURLWithPath: "/tmp/claudex-ui/catalog-fixture"), loader: { throw SIWCError.remote("Fixture catalog unavailable. Try refreshing.") })
        let model = AppModel(configurationStore: storeFactory?(config) ?? PreviewConfigurationStore(config), modelCatalog: catalog, automaticallyLoadCatalog: false, offlinePreview: true)
        model.tracePath = "/tmp/claudex-ui/fixture-trace-unused"
        model.traffic = traffic
        model.authState = .ready; model.authText = "ChatGPT connected"; model.statusText = "Gateway paused"
        model.chatGPTAccounts = [SIWCAccountSummary(id: "demo-account", label: "Alex · Personal workspace", clientID: "fixture-client", active: true, authorized: true)]
        var json = """
        {"accountID":"demo-account","fetchedAt":\(Date().timeIntervalSinceReferenceDate),"models":[{"id":"gpt-6-luna","label":"GPT-6 Luna","accountID":"demo-account","details":{"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"supports_parallel_tool_calls":true,"support_verbosity":true}},{"id":"gpt-6-sol","label":"GPT-6 Sol","accountID":"demo-account","details":{"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}}]}
        """
        if state == "longMetadata" {
            let note = String(data: try! JSONEncoder().encode(String(repeating: "LONG_METADATA_WORD_", count: 600)), encoding: .utf8)!
            json = json.replacingOccurrences(of: "\"supports_parallel_tool_calls\":true", with: "\"fixture_note\":" + note + ",\"supports_parallel_tool_calls\":true")
        }
        let snapshot = try! JSONDecoder().decode(SIWCModelCatalogSnapshot.self, from: Data(json.utf8))
        model.modelCatalogSnapshot = snapshot; model.availableChatGPTModels = snapshot.models
        switch state {
        case "signedOut": model.chatGPTAccounts = []; model.authState = .authorizationRequired; model.modelCatalogSnapshot = nil; model.availableChatGPTModels = []
        case "signingIn": model.chatGPTAccounts = []; model.authState = .authorizationRequired; model.modelCatalogSnapshot = nil; model.availableChatGPTModels = []; model.isSigningIn = true
        case "authError": model.chatGPTAccounts = []; model.authState = .authorizationRequired; model.modelCatalogSnapshot = nil; model.availableChatGPTModels = []; model.signInError = "Connection was interrupted. Connect ChatGPT to try again."
        case "loading": model.modelCatalogSnapshot = nil; model.availableChatGPTModels = []; model.isLoadingModelCatalog = true
        case "catalogError", "switched": model.modelCatalogSnapshot = nil; model.availableChatGPTModels = []; model.modelCatalogError = "Could not load models for this account. Refresh to try again."
        case "running": model.daemonState = "running"; model.statusText = "Gateway running"; model.activeRequestCount = 1
        case "idle": model.daemonState = "running"; model.statusText = "Gateway running"; model.activeRequestCount = 0
        case "gatewayError": model.statusText = "Failed to start gateway: port 4317 is already in use. Pause the other gateway or change the port in Gateway settings."
        default: break
        }
        return model
    }
}
#endif

// MARK: - Menu bar popover

struct RecordedRequestTrend: Equatable {
    init(buckets: [Int], available: Bool) { self.buckets = buckets; self.available = available }
    let buckets: [Int]
    let available: Bool
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    private var trend: RecordedRequestTrend { RecordedRequestTrend(buckets: model.traffic?.buckets ?? Array(repeating: 0, count: 5), available: model.traffic != nil) }
    private var trafficWindow: String {
        guard let start = model.traffic?.startedAt, Date().timeIntervalSince(start) < 300 else { return "Last 5 min" }
        return "Since " + start.formatted(date: .omitted, time: .shortened)
    }
    private func number(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    private var error: String? {
        if let value = model.signInError ?? model.tokenRefreshError ?? model.doctorSnapshot?.authError { return value }
        if model.statusText.hasPrefix("Failed") { return model.statusText }
        if !model.isUpstreamReady { return model.isSigningIn ? "Connecting ChatGPT…" : "ChatGPT connection needed" }
        if !model.daemonIsRunning, let value = model.savedRoutingCatalogError { return value }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                MBDot(state: error != nil ? .fault : (model.daemonIsRunning ? .live : .idle), size: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.daemonIsRunning ? "Gateway running" : "Gateway paused").font(.system(size: 13, weight: .semibold))
                    Text(model.activeRequestCount.map { $0 == 0 ? "Idle" : "\($0) active request\($0 == 1 ? "" : "s")" } ?? (model.daemonIsRunning ? "Active requests unavailable" : "Idle"))
                        .font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                }
                Spacer(minLength: 8)
                Button(model.daemonIsRunning ? "Pause" : "Start") { model.toggleDaemon() }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!model.canStartDaemon)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(MBFont.caption).foregroundStyle(MBColor.faultInk).lineLimit(2).help(error)
            } else if let recordedError = model.recentErrorReasons.first {
                Text("Last recorded error: " + recordedError).font(MBFont.caption)
                    .foregroundStyle(MBColor.warnInk).lineLimit(2).help(recordedError)
            }
            Divider()
            HStack {
                Text("Requests/min").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                Spacer()
                Text(trafficWindow).font(MBFont.caption).foregroundStyle(MBColor.inkFaint)
            }
            RequestTrendLine(trend: trend).frame(height: 35)
            HStack(alignment: .top, spacing: 12) {
                PanelMetric(label: "Requests", value: model.traffic.map { number($0.requests) } ?? "—")
                PanelMetric(label: "Tokens", value: model.traffic.map { $0.usageReported ? number($0.inputTokens + $0.outputTokens) + ($0.usageIncomplete ? "+" : "") : "—" } ?? "—")
                    .help("Provider-reported input + output tokens in this window. Includes Advisor; + means some calls did not report usage. Not remaining plan quota.")
                PanelMetric(label: "Errors", value: model.traffic.map { number($0.errors) } ?? "—", warning: (model.traffic?.errors ?? 0) > 0)
            }
            if let traffic = model.traffic {
                HStack {
                    Text("\(traffic.modelCalls) model calls")
                    Spacer()
                    if traffic.advisorTokens > 0 { Text("Advisor · " + number(traffic.advisorTokens) + " tokens") }
                    else if let latency = traffic.lastLatencyMilliseconds { Text("Last · " + (Double(latency) / 1000).formatted(.number.precision(.fractionLength(1))) + " s") }
                }.font(MBFont.caption).foregroundStyle(MBColor.inkDim).monospacedDigit()
            }
            HStack {
                Spacer(minLength: 0)
                Button { model.settingsTab = .diagnostics; openSettings() } label: {
                    Label("Activity", systemImage: "waveform.path")
                }
                Button { model.settingsTab = .upstream; openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }.buttonStyle(.borderless).controlSize(.small).font(MBFont.caption)
        }
        .font(MBFont.label).tint(MBColor.brand).padding(14).frame(width: 340).background(MBColor.paper)
    }
}

private struct PanelMetric: View {
    let label: String
    let value: String
    var warning = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
                .foregroundStyle(warning ? MBColor.warnInk : MBColor.ink)
            Text(label).font(MBFont.caption).foregroundStyle(MBColor.inkDim)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RequestTrendLine: View {
    let trend: RecordedRequestTrend
    var body: some View {
        if !trend.available {
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(MBColor.inkFaint)
                Text("Trend unavailable · no request timestamps").font(MBFont.caption).foregroundStyle(MBColor.inkFaint)
                Spacer()
            }
        } else {
            GeometryReader { geometry in
                let maximum = max(1, trend.buckets.max() ?? 1)
                Path { path in
                    for (index, count) in trend.buckets.enumerated() {
                        let point = CGPoint(x: CGFloat(index) * max(0, geometry.size.width - 80) / 4,
                            y: geometry.size.height - 2 - CGFloat(count) / CGFloat(maximum) * (geometry.size.height - 4))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(MBColor.brand.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                HStack {
                    Spacer()
                    Text("Peak \(trend.buckets.max() ?? 0)/min").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                }
            }.accessibilityLabel("Recorded requests per minute over the last five minutes: " + trend.buckets.map(String.init).joined(separator: ", "))
        }
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
        .lineLimit(1)
        .fixedSize()
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
