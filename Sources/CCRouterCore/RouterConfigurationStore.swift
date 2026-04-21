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
                executorModel: nil,
                advisorModel: nil,
                gatewayAuthToken: nil,
                gatewayAuthHeader: nil,
                subscriptionAuthFilePath: nil
            ))
            stored = created
            writeWarning = persist(configuration: created, to: storageURL)
        }

        return resolveConfiguration(
            stored: stored,
            storageURL: storageURL,
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
                executorModel: configuration.executorModel,
                advisorModel: configuration.advisorModel,
                gatewayAuthToken: configuration.gatewayAuthToken,
                gatewayAuthHeader: configuration.gatewayAuthHeader,
                subscriptionAuthFilePath: configuration.subscriptionAuthFilePath
            )
        )
        let writeWarning = persist(configuration: stored, to: location.url)
        return resolveConfiguration(
            stored: stored,
            storageURL: location.url,
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
                executorModel: configuration.executorModel,
                advisorModel: configuration.advisorModel,
                gatewayAuthToken: makeGatewayToken(),
                gatewayAuthHeader: configuration.gatewayAuthHeader,
                subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
                configurationPath: configuration.configurationPath,
                configurationWarning: configuration.configurationWarning
            )
        )
    }

    private func resolveConfiguration(
        stored: StoredConfiguration,
        storageURL: URL,
        locationWarning: String?,
        writeWarning: String?
    ) -> RouterConfiguration {
        let warnings = [locationWarning, writeWarning].compactMap { $0 }.joined(separator: " ")
        return RouterConfiguration(
            host: environment["CC_ROUTER_HOST"] ?? stored.host ?? "127.0.0.1",
            port: parsePort(environment["CC_ROUTER_PORT"]) ?? stored.port ?? 4317,
            healthPath: stored.healthPath ?? "/health",
            messagesPath: stored.messagesPath ?? "/v1/messages",
            countTokensPath: stored.countTokensPath ?? "/v1/messages/count_tokens",
            responsesURL: environment["CC_ROUTER_RESPONSES_URL"] ?? stored.responsesURL ?? "https://chatgpt.com/backend-api/codex/responses",
            executorModel: environment["CC_ROUTER_EXECUTOR_MODEL"] ?? stored.executorModel ?? "gpt-5.4",
            advisorModel: environment["CC_ROUTER_ADVISOR_MODEL"] ?? stored.advisorModel ?? "gpt-5.4",
            gatewayAuthToken: environment["CC_ROUTER_GATEWAY_TOKEN"] ?? stored.gatewayAuthToken ?? makeGatewayToken(),
            gatewayAuthHeader: stored.gatewayAuthHeader ?? "x-api-key",
            subscriptionAuthFilePath: environment["CC_ROUTER_SUBSCRIPTION_AUTH_FILE"] ?? stored.subscriptionAuthFilePath ?? homeDirectoryURL.appendingPathComponent(".codex/auth.json").path,
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

    private func normalizedConfiguration(from configuration: StoredConfiguration) -> StoredConfiguration {
        StoredConfiguration(
            host: configuration.host ?? environment["CC_ROUTER_HOST"] ?? "127.0.0.1",
            port: configuration.port ?? parsePort(environment["CC_ROUTER_PORT"]) ?? 4317,
            healthPath: configuration.healthPath ?? "/health",
            messagesPath: configuration.messagesPath ?? "/v1/messages",
            countTokensPath: configuration.countTokensPath ?? "/v1/messages/count_tokens",
            responsesURL: configuration.responsesURL ?? environment["CC_ROUTER_RESPONSES_URL"] ?? "https://chatgpt.com/backend-api/codex/responses",
            executorModel: configuration.executorModel ?? environment["CC_ROUTER_EXECUTOR_MODEL"] ?? "gpt-5.4",
            advisorModel: configuration.advisorModel ?? environment["CC_ROUTER_ADVISOR_MODEL"] ?? "gpt-5.4",
            gatewayAuthToken: configuration.gatewayAuthToken ?? environment["CC_ROUTER_GATEWAY_TOKEN"] ?? makeGatewayToken(),
            gatewayAuthHeader: configuration.gatewayAuthHeader ?? "x-api-key",
            subscriptionAuthFilePath: configuration.subscriptionAuthFilePath ?? environment["CC_ROUTER_SUBSCRIPTION_AUTH_FILE"] ?? homeDirectoryURL.appendingPathComponent(".codex/auth.json").path
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
            .appendingPathComponent("Library/Application Support/ModelBridge", isDirectory: true)
            .appendingPathComponent("config.json")

        do {
            try ensureParentDirectory(for: primary)
            return (primary, nil)
        } catch {
            let fallback = URL(fileURLWithPath: "/tmp/modelbridge/config.json")
            return (
                fallback,
                "Application Support is not writable; using fallback configuration path /tmp/modelbridge/config.json."
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

private struct StoredConfiguration: Codable {
    let host: String?
    let port: Int?
    let healthPath: String?
    let messagesPath: String?
    let countTokensPath: String?
    let responsesURL: String?
    let executorModel: String?
    let advisorModel: String?
    let gatewayAuthToken: String?
    let gatewayAuthHeader: String?
    let subscriptionAuthFilePath: String?
}
