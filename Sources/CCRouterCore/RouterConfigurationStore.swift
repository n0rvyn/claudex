import Foundation

public struct RouterConfigurationStore {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let homeDirectoryURL: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
    }

    public func loadOrCreate() -> RouterConfiguration {
        let location = resolveConfigurationLocation()
        let storageURL = location.url
        let homeWarning = UserHomeResolver.containerizationWarning(
            fallbackHomeDirectoryURL: homeDirectoryURL
        )
        let writeWarning: String?
        let stored: StoredConfiguration

        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            let normalized = normalizedConfiguration(from: decoded)
            stored = normalized
            writeWarning = persist(configuration: normalized, to: storageURL)
        } else {
            let created = normalizedConfiguration(from: StoredConfiguration(
                host: nil,
                port: nil,
                healthPath: nil,
                messagesPath: nil,
                countTokensPath: nil,
                responsesURL: nil,
                routingTable: nil,
                advisorRoute: nil,
                executorModel: nil,
                advisorModel: nil,
                gatewayAuthToken: nil,
                gatewayAuthHeader: nil,
                subscriptionAuthFilePath: nil,
                subscriptionAuthBookmarkData: nil,
                pendingToolTurnTTLSeconds: nil,
                advisorContextMessageLimit: nil
            ))
            stored = created
            writeWarning = persist(configuration: created, to: storageURL)
        }

        return resolveConfiguration(
            stored: stored,
            storageURL: storageURL,
            homeWarning: homeWarning,
            locationWarning: location.warning,
            writeWarning: writeWarning
        )
    }

    public func save(configuration: RouterConfiguration) -> RouterConfiguration {
        let location = resolveConfigurationLocation()
        let stored = normalizedConfiguration(
            from: StoredConfiguration(
                host: configuration.host,
                port: configuration.port,
                healthPath: configuration.healthPath,
                messagesPath: configuration.messagesPath,
                countTokensPath: configuration.countTokensPath,
                responsesURL: configuration.responsesURL,
                routingTable: configuration.routingTable,
                advisorRoute: configuration.advisorRoute,
                executorModel: nil,   // do not write legacy keys to disk
                advisorModel: nil,
                gatewayAuthToken: configuration.gatewayAuthToken,
                gatewayAuthHeader: configuration.gatewayAuthHeader,
                subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
                subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
                pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,
                advisorContextMessageLimit: configuration.advisorContextMessageLimit
            )
        )
        let writeWarning = persist(configuration: stored, to: location.url)
        return resolveConfiguration(
            stored: stored,
            storageURL: location.url,
            homeWarning: UserHomeResolver.containerizationWarning(
                fallbackHomeDirectoryURL: homeDirectoryURL
            ),
            locationWarning: location.warning,
            writeWarning: writeWarning
        )
    }

    public func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration {
        save(
            configuration: RouterConfiguration(
                host: configuration.host,
                port: configuration.port,
                healthPath: configuration.healthPath,
                messagesPath: configuration.messagesPath,
                countTokensPath: configuration.countTokensPath,
                responsesURL: configuration.responsesURL,
                routingTable: configuration.routingTable,
                advisorRoute: configuration.advisorRoute,
                pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,
                advisorContextMessageLimit: configuration.advisorContextMessageLimit,
                gatewayAuthToken: makeGatewayToken(),
                gatewayAuthHeader: configuration.gatewayAuthHeader,
                subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
                subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
                configurationPath: configuration.configurationPath,
                configurationWarning: configuration.configurationWarning
            )
        )
    }

    // MARK: - Private helpers

    private func resolveConfiguration(
        stored: StoredConfiguration,
        storageURL: URL,
        homeWarning: String?,
        locationWarning: String?,
        writeWarning: String?
    ) -> RouterConfiguration {
        let warnings = [homeWarning, locationWarning, writeWarning].compactMap { $0 }.joined(separator: " ")

        let routingTable: ModelRoutingTable
        if let envExec = environment["CC_ROUTER_EXECUTOR_MODEL"] {
            // env override: replace only the fallback upstreamModel, keep stored.rules intact.
            let baseRules = stored.routingTable?.rules ?? []
            routingTable = ModelRoutingTable(
                rules: baseRules,
                fallback: ModelRoute(upstreamModel: envExec, reasoningEffort: "xhigh", textVerbosity: "low")
            )
        } else if let table = stored.routingTable {
            routingTable = table
        } else {
            // No stored table and no env override: single-rule fallback from legacy fields.
            let upstream = stored.executorModel ?? "gpt-5.4"
            routingTable = ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: upstream, reasoningEffort: "xhigh", textVerbosity: "low")
            )
        }

        let advisorRoute: ModelRoute
        if let envAdv = environment["CC_ROUTER_ADVISOR_MODEL"] {
            advisorRoute = ModelRoute(upstreamModel: envAdv, reasoningEffort: "xhigh", textVerbosity: "low")
        } else if let route = stored.advisorRoute {
            advisorRoute = route
        } else {
            let upstream = stored.advisorModel ?? "gpt-5.4"
            advisorRoute = ModelRoute(upstreamModel: upstream, reasoningEffort: "xhigh", textVerbosity: "low")
        }

        return RouterConfiguration(
            host: environment["CC_ROUTER_HOST"] ?? stored.host ?? "127.0.0.1",
            port: parsePort(environment["CC_ROUTER_PORT"]) ?? stored.port ?? 4317,
            healthPath: stored.healthPath ?? "/health",
            messagesPath: stored.messagesPath ?? "/v1/messages",
            countTokensPath: stored.countTokensPath ?? "/v1/messages/count_tokens",
            responsesURL: environment["CC_ROUTER_RESPONSES_URL"] ?? stored.responsesURL ?? "https://chatgpt.com/backend-api/codex/responses",
            routingTable: routingTable,
            advisorRoute: advisorRoute,
            pendingToolTurnTTLSeconds: stored.pendingToolTurnTTLSeconds ?? 1800,
            advisorContextMessageLimit: stored.advisorContextMessageLimit ?? 8,
            gatewayAuthToken: environment["CC_ROUTER_GATEWAY_TOKEN"] ?? stored.gatewayAuthToken ?? makeGatewayToken(),
            gatewayAuthHeader: stored.gatewayAuthHeader ?? "x-api-key",
            subscriptionAuthFilePath: resolvedSubscriptionAuthFilePath(storedPath: stored.subscriptionAuthFilePath),
            subscriptionAuthBookmarkData: stored.subscriptionAuthBookmarkData,
            configurationPath: storageURL.path,
            configurationWarning: warnings.isEmpty ? nil : warnings
        )
    }

    private func persist(configuration: StoredConfiguration, to url: URL) -> String? {
        do {
            try ensureParentDirectory(for: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "Configuration file is not writable at \(url.path): \(error.localizedDescription)"
        }
    }

    /// Normalizes a raw StoredConfiguration read from disk, filling defaults and
    /// applying the routing-table migration:
    ///   - Legacy file with only executorModel/advisorModel → single-rule table.
    ///   - Fresh install (all nil, no env vars) → ModelRoutingTable.defaultTable.
    private func normalizedConfiguration(from configuration: StoredConfiguration) -> StoredConfiguration {
        let routingTable: ModelRoutingTable
        if let table = configuration.routingTable {
            routingTable = table
        } else if let legacyExec = configuration.executorModel ?? environment["CC_ROUTER_EXECUTOR_MODEL"] {
            // Legacy migration: preserve single-rule shape.
            routingTable = ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: legacyExec, reasoningEffort: "xhigh", textVerbosity: "low")
            )
        } else {
            // Fresh install: ship 3-rule baseline so opus/sonnet/haiku fan out immediately.
            routingTable = .defaultTable
        }

        let advisorRoute: ModelRoute
        if let route = configuration.advisorRoute {
            advisorRoute = route
        } else if let legacyAdvisor = configuration.advisorModel ?? environment["CC_ROUTER_ADVISOR_MODEL"] {
            advisorRoute = ModelRoute(upstreamModel: legacyAdvisor, reasoningEffort: "xhigh", textVerbosity: "low")
        } else {
            advisorRoute = ModelRoutingTable.defaultAdvisorRoute
        }

        return StoredConfiguration(
            host: configuration.host ?? environment["CC_ROUTER_HOST"] ?? "127.0.0.1",
            port: configuration.port ?? parsePort(environment["CC_ROUTER_PORT"]) ?? 4317,
            healthPath: configuration.healthPath ?? "/health",
            messagesPath: configuration.messagesPath ?? "/v1/messages",
            countTokensPath: configuration.countTokensPath ?? "/v1/messages/count_tokens",
            responsesURL: configuration.responsesURL ?? environment["CC_ROUTER_RESPONSES_URL"] ?? "https://chatgpt.com/backend-api/codex/responses",
            routingTable: routingTable,
            advisorRoute: advisorRoute,
            executorModel: nil,   // strip legacy keys on write
            advisorModel: nil,
            gatewayAuthToken: configuration.gatewayAuthToken ?? environment["CC_ROUTER_GATEWAY_TOKEN"] ?? makeGatewayToken(),
            gatewayAuthHeader: configuration.gatewayAuthHeader ?? "x-api-key",
            subscriptionAuthFilePath: resolvedSubscriptionAuthFilePath(storedPath: configuration.subscriptionAuthFilePath),
            subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
            pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,
            advisorContextMessageLimit: configuration.advisorContextMessageLimit
        )
    }

    private func resolvedSubscriptionAuthFilePath(storedPath: String?) -> String {
        if let overridePath = environment["CC_ROUTER_SUBSCRIPTION_AUTH_FILE"], !overridePath.isEmpty {
            return overridePath
        }
        if let storedPath, !storedPath.isEmpty, !UserHomeResolver.shouldReplaceContainerizedAuthPath(storedPath) {
            return storedPath
        }
        return UserHomeResolver.defaultSubscriptionAuthFilePath(
            fallbackHomeDirectoryURL: homeDirectoryURL
        )
    }

    private func ensureParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func resolveConfigurationLocation() -> (url: URL, warning: String?) {
        if let overridePath = environment["CC_ROUTER_CONFIG_PATH"], !overridePath.isEmpty {
            return (URL(fileURLWithPath: overridePath), nil)
        }

        let primary = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/Claudex", isDirectory: true)
            .appendingPathComponent("config.json")

        do {
            try ensureParentDirectory(for: primary)
            return (primary, nil)
        } catch {
            let fallback = URL(fileURLWithPath: "/tmp/claudex/config.json")
            return (
                fallback,
                "Application Support is not writable; using fallback configuration path /tmp/claudex/config.json."
            )
        }
    }

    private func parsePort(_ rawValue: String?) -> Int? {
        guard let rawValue, let port = Int(rawValue) else { return nil }
        guard (1...65_535).contains(port) else { return nil }
        return port
    }

    private func makeGatewayToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - Stored configuration (disk shape)

private struct StoredConfiguration: Codable {
    let host: String?
    let port: Int?
    let healthPath: String?
    let messagesPath: String?
    let countTokensPath: String?
    let responsesURL: String?
    // New keys (canonical — always written).
    let routingTable: ModelRoutingTable?
    let advisorRoute: ModelRoute?
    // Legacy keys (read-only for migration from old config.json files).
    let executorModel: String?
    let advisorModel: String?
    let gatewayAuthToken: String?
    let gatewayAuthHeader: String?
    let subscriptionAuthFilePath: String?
    let subscriptionAuthBookmarkData: Data?
    // Phase 4 fields (no inline defaults — plain optionals for Codable synthesis).
    let pendingToolTurnTTLSeconds: Int?
    let advisorContextMessageLimit: Int?
}
