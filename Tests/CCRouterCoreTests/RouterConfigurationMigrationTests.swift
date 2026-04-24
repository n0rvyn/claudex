import Foundation
@testable import CCRouterCore
import Testing

struct RouterConfigurationMigrationTests {
    @Test
    func legacyFlatFieldsMigrateToSingleRuleFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Write old-format config.json (no routingTable/advisorRoute keys).
        let legacyJSON: [String: Any] = [
            "host": "127.0.0.1",
            "port": 4317,
            "healthPath": "/health",
            "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "executorModel": "gpt-5.4-legacy-exec",
            "advisorModel": "gpt-5.4-legacy-advisor",
            "gatewayAuthToken": "legacy-token",
            "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON, options: .prettyPrinted)
        try data.write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        // Legacy executorModel landed in fallback.upstreamModel.
        #expect(configuration.routingTable.fallback.upstreamModel == "gpt-5.4-legacy-exec")
        #expect(configuration.routingTable.rules.isEmpty)   // no opus/sonnet/haiku rules added.
        #expect(configuration.advisorRoute.upstreamModel == "gpt-5.4-legacy-advisor")
        // Derived compatibility properties still work.
        #expect(configuration.executorModel == "gpt-5.4-legacy-exec")
        #expect(configuration.advisorModel == "gpt-5.4-legacy-advisor")
    }

    @Test
    func loadThenSaveStripsLegacyFieldsFromDisk() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let legacyJSON: [String: Any] = [
            "host": "127.0.0.1", "port": 4317,
            "healthPath": "/health", "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "executorModel": "gpt-5.4-e", "advisorModel": "gpt-5.4-a",
            "gatewayAuthToken": "t", "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )
        _ = store.loadOrCreate()   // first load triggers persist (normalizedConfiguration strips legacy keys)

        let diskBytes = try Data(contentsOf: configPathURL)
        let json = try JSONSerialization.jsonObject(with: diskBytes) as? [String: Any] ?? [:]
        #expect(json["executorModel"] == nil)
        #expect(json["advisorModel"] == nil)
        #expect(json["routingTable"] != nil)
        #expect(json["advisorRoute"] != nil)
    }

    @Test
    func envExecutorModelOverridesFallbackUpstream() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: [
                "CC_ROUTER_CONFIG_PATH": configPath,
                "CC_ROUTER_EXECUTOR_MODEL": "env-override-exec",
            ],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()
        #expect(configuration.routingTable.fallback.upstreamModel == "env-override-exec")
        #expect(configuration.executorModel == "env-override-exec")
    }

    @Test
    func freshInstallGetsDefaultThreeRuleTable() throws {
        // No config.json and no env override — loadOrCreate must synthesize ModelRoutingTable.defaultTable.
        // This is required for Phase 2 acceptance #4+#5 (opus/sonnet/haiku fan-out).
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        // Do NOT pre-write a config.json.
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        #expect(configuration.routingTable == ModelRoutingTable.defaultTable)
        #expect(configuration.routingTable.rules.count == 3)
        #expect(configuration.routingTable.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(configuration.routingTable.resolve(for: "claude-sonnet-4-6").upstreamModel == "gpt-5.4")
        #expect(configuration.routingTable.resolve(for: "claude-haiku-4-5-20251001").upstreamModel == "gpt-5.3-codex-spark")
        #expect(configuration.advisorRoute == ModelRoutingTable.defaultAdvisorRoute)
    }

    @Test
    func newFormatConfigLoadsWithRoutingTableIntact() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let newJSON: [String: Any] = [
            "host": "127.0.0.1", "port": 4317,
            "healthPath": "/health", "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "routingTable": [
                "rules": [
                    ["match": "opus", "route": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"]],
                    ["match": "haiku", "route": ["upstreamModel": "gpt-5.3-codex", "reasoningEffort": "medium", "textVerbosity": "low"]],
                ],
                "fallback": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"]
            ],
            "advisorRoute": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"],
            "gatewayAuthToken": "t", "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        try JSONSerialization.data(withJSONObject: newJSON, options: []).write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )
        let config = store.loadOrCreate()

        #expect(config.routingTable.rules.count == 2)
        #expect(config.routingTable.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(config.routingTable.resolve(for: "claude-haiku-4-5").reasoningEffort == "medium")
    }

    @Test
    func legacyConfigWithoutPhase4FieldsUsesDefaults() throws {
        let legacyJSON = """
        { "host":"127.0.0.1", "port":4317, "healthPath":"/health", "messagesPath":"/v1/messages",
          "countTokensPath":"/v1/messages/count_tokens",
          "responsesURL":"https://chatgpt.com/backend-api/codex/responses",
          "executorModel":"gpt-5.4", "advisorModel":"gpt-5.4",
          "gatewayAuthToken":"tok", "gatewayAuthHeader":"x-api-key",
          "subscriptionAuthFilePath":"/dev/null/auth.json",
          "configurationPath":"/dev/null/config.json" }
        """
        let decoded = try JSONDecoder().decode(RouterConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(decoded.pendingToolTurnTTLSeconds == 1800)
        #expect(decoded.advisorContextMessageLimit == 8)
    }

    @Test
    func phase4FieldsRoundTripThroughCodable() throws {
        let original = RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://example/",
            routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            pendingToolTurnTTLSeconds: 600,
            advisorContextMessageLimit: 4,
            gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouterConfiguration.self, from: data)
        #expect(decoded.pendingToolTurnTTLSeconds == 600)
        #expect(decoded.advisorContextMessageLimit == 4)
    }

    /// Rotation path (RouterConfigurationStore.regenerateGatewayToken) must preserve Phase 4 fields.
    /// Regression for the silent data-loss failure mode flagged by plan-verifier.
    @Test
    func tokenRegenerationPreservesPhase4Fields() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let configPath = tempDir.appendingPathComponent("config.json")

        let store = RouterConfigurationStore(
            environment: [:],
            fileManager: .default,
            homeDirectoryURL: tempDir
        )

        let initial = RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://example/",
            routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            pendingToolTurnTTLSeconds: 600,
            advisorContextMessageLimit: 4,
            gatewayAuthToken: "initial-tok",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: configPath.path,
            configurationWarning: nil
        )
        _ = store.save(configuration: initial)

        let rotated = store.regenerateGatewayToken(from: initial)

        #expect(rotated.pendingToolTurnTTLSeconds == 600)
        #expect(rotated.advisorContextMessageLimit == 4)
        #expect(rotated.gatewayAuthToken != "initial-tok")   // actually rotated
    }

    @Test
    func saveReloadRoundTripPreservesPhase4Fields() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store1 = RouterConfigurationStore(
            environment: [:],
            fileManager: .default,
            homeDirectoryURL: tempDir
        )

        let initial = RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://example/",
            routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            pendingToolTurnTTLSeconds: 600,
            advisorContextMessageLimit: 4,
            gatewayAuthToken: "tok",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "ignored-will-be-replaced",
            configurationWarning: nil
        )
        _ = store1.save(configuration: initial)
        // Disk now has config.json under tempDir.

        // Fresh store instance reads from disk (simulates daemon restart).
        let store2 = RouterConfigurationStore(
            environment: [:],
            fileManager: .default,
            homeDirectoryURL: tempDir
        )
        let reloaded = store2.loadOrCreate()

        #expect(reloaded.pendingToolTurnTTLSeconds == 600)
        #expect(reloaded.advisorContextMessageLimit == 4)
    }
}
