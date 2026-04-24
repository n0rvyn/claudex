import Foundation

public struct RouterConfiguration: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let healthPath: String
    public let messagesPath: String
    public let countTokensPath: String
    public let responsesURL: String
    public let routingTable: ModelRoutingTable
    public let advisorRoute: ModelRoute
    public let pendingToolTurnTTLSeconds: Int
    public let advisorContextMessageLimit: Int
    public let gatewayAuthToken: String
    public let gatewayAuthHeader: String
    public let subscriptionAuthFilePath: String
    public let subscriptionAuthBookmarkData: Data?
    public let configurationPath: String
    public let configurationWarning: String?

    /// Derived field: backward-compatible read path for DoctorSnapshot / ContentView / SettingsView.
    public var executorModel: String { routingTable.fallback.upstreamModel }
    /// Derived field: backward-compatible read path.
    public var advisorModel: String { advisorRoute.upstreamModel }

    // MARK: - Canonical init

    public init(
        host: String,
        port: Int,
        healthPath: String,
        messagesPath: String,
        countTokensPath: String,
        responsesURL: String,
        routingTable: ModelRoutingTable,
        advisorRoute: ModelRoute,
        pendingToolTurnTTLSeconds: Int = 1800,
        advisorContextMessageLimit: Int = 8,
        gatewayAuthToken: String,
        gatewayAuthHeader: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data? = nil,
        configurationPath: String,
        configurationWarning: String?
    ) {
        self.host = host
        self.port = port
        self.healthPath = healthPath
        self.messagesPath = messagesPath
        self.countTokensPath = countTokensPath
        self.responsesURL = responsesURL
        self.routingTable = routingTable
        self.advisorRoute = advisorRoute
        self.pendingToolTurnTTLSeconds = pendingToolTurnTTLSeconds
        self.advisorContextMessageLimit = advisorContextMessageLimit
        self.gatewayAuthToken = gatewayAuthToken
        self.gatewayAuthHeader = gatewayAuthHeader
        self.subscriptionAuthFilePath = subscriptionAuthFilePath
        self.subscriptionAuthBookmarkData = subscriptionAuthBookmarkData
        self.configurationPath = configurationPath
        self.configurationWarning = configurationWarning
    }

    // MARK: - Legacy init (DP-001-P2 Option A)

    /// Constructs a single-rule empty table with the given strings as the fallback / advisor upstream.
    /// Used by ContentView.swift and existing tests that pass raw executor/advisor model strings.
    @available(*, deprecated, message: "Wipes routingTable.rules to []. Use the canonical init with explicit routingTable: + advisorRoute: parameters. See DP-002 (review report 2026-04-22-182242).")
    public init(
        host: String,
        port: Int,
        healthPath: String,
        messagesPath: String,
        countTokensPath: String,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        gatewayAuthToken: String,
        gatewayAuthHeader: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data? = nil,
        configurationPath: String,
        configurationWarning: String?
    ) {
        self.init(
            host: host, port: port,
            healthPath: healthPath, messagesPath: messagesPath,
            countTokensPath: countTokensPath, responsesURL: responsesURL,
            routingTable: ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: executorModel, reasoningEffort: "xhigh", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: advisorModel, reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: gatewayAuthToken,
            gatewayAuthHeader: gatewayAuthHeader,
            subscriptionAuthFilePath: subscriptionAuthFilePath,
            subscriptionAuthBookmarkData: subscriptionAuthBookmarkData,
            configurationPath: configurationPath,
            configurationWarning: configurationWarning
        )
    }

    // MARK: - Convenience init from store

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self = RouterConfigurationStore(
            environment: environment,
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL
        ).loadOrCreate()
    }

    // MARK: - Codable (manual — preserves migration from legacy JSON keys)

    private enum CodingKeys: String, CodingKey {
        case host, port, healthPath, messagesPath, countTokensPath, responsesURL
        case routingTable, advisorRoute
        case pendingToolTurnTTLSeconds, advisorContextMessageLimit
        case executorModel, advisorModel
        case gatewayAuthToken, gatewayAuthHeader
        case subscriptionAuthFilePath, subscriptionAuthBookmarkData
        case configurationPath, configurationWarning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        healthPath = try c.decode(String.self, forKey: .healthPath)
        messagesPath = try c.decode(String.self, forKey: .messagesPath)
        countTokensPath = try c.decode(String.self, forKey: .countTokensPath)
        responsesURL = try c.decode(String.self, forKey: .responsesURL)

        if let table = try c.decodeIfPresent(ModelRoutingTable.self, forKey: .routingTable) {
            routingTable = table
        } else {
            let legacyExecutor = try c.decodeIfPresent(String.self, forKey: .executorModel) ?? "gpt-5.4"
            routingTable = ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: legacyExecutor, reasoningEffort: "xhigh", textVerbosity: "low")
            )
        }

        if let route = try c.decodeIfPresent(ModelRoute.self, forKey: .advisorRoute) {
            advisorRoute = route
        } else {
            let legacyAdvisor = try c.decodeIfPresent(String.self, forKey: .advisorModel) ?? "gpt-5.4"
            advisorRoute = ModelRoute(upstreamModel: legacyAdvisor, reasoningEffort: "xhigh", textVerbosity: "low")
        }

        pendingToolTurnTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .pendingToolTurnTTLSeconds) ?? 1800
        advisorContextMessageLimit = try c.decodeIfPresent(Int.self, forKey: .advisorContextMessageLimit) ?? 8

        gatewayAuthToken = try c.decode(String.self, forKey: .gatewayAuthToken)
        gatewayAuthHeader = try c.decode(String.self, forKey: .gatewayAuthHeader)
        subscriptionAuthFilePath = try c.decode(String.self, forKey: .subscriptionAuthFilePath)
        subscriptionAuthBookmarkData = try c.decodeIfPresent(Data.self, forKey: .subscriptionAuthBookmarkData)
        configurationPath = try c.decode(String.self, forKey: .configurationPath)
        configurationWarning = try c.decodeIfPresent(String.self, forKey: .configurationWarning)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(healthPath, forKey: .healthPath)
        try c.encode(messagesPath, forKey: .messagesPath)
        try c.encode(countTokensPath, forKey: .countTokensPath)
        try c.encode(responsesURL, forKey: .responsesURL)
        try c.encode(routingTable, forKey: .routingTable)
        try c.encode(advisorRoute, forKey: .advisorRoute)
        try c.encode(pendingToolTurnTTLSeconds, forKey: .pendingToolTurnTTLSeconds)
        try c.encode(advisorContextMessageLimit, forKey: .advisorContextMessageLimit)
        try c.encode(gatewayAuthToken, forKey: .gatewayAuthToken)
        try c.encode(gatewayAuthHeader, forKey: .gatewayAuthHeader)
        try c.encode(subscriptionAuthFilePath, forKey: .subscriptionAuthFilePath)
        try c.encodeIfPresent(subscriptionAuthBookmarkData, forKey: .subscriptionAuthBookmarkData)
        try c.encode(configurationPath, forKey: .configurationPath)
        try c.encodeIfPresent(configurationWarning, forKey: .configurationWarning)
        // Legacy keys (executorModel/advisorModel) are NOT written to disk — migration happens on first read.
    }

    // MARK: - Helpers

    public var endpoint: String {
        "http://\(host):\(port)"
    }

    public var gatewayAuthTokenSuffix: String {
        String(gatewayAuthToken.suffix(6))
    }

    public var claudeEnvironmentSnippet: String {
        "ANTHROPIC_BASE_URL=\(endpoint)\nANTHROPIC_AUTH_TOKEN=\(gatewayAuthToken)"
    }
}
