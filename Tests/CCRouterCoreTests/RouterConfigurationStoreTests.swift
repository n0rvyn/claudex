import Foundation
import Testing
@testable import CCRouterCore

struct RouterConfigurationStoreTests {
    @Test
    func loadOrCreatePersistsGatewayToken() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let first = store.loadOrCreate()
        let second = store.loadOrCreate()

        #expect(first.gatewayAuthToken == second.gatewayAuthToken)
        #expect(first.configurationPath == configPath)
        #expect(FileManager.default.fileExists(atPath: configPath))
    }

    @Test
    func environmentOverridesBecomeEffectiveConfiguration() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: [
                "CC_ROUTER_CONFIG_PATH": configPath,
                "CC_ROUTER_HOST": "127.0.0.2",
                "CC_ROUTER_PORT": "4999",
                "CC_ROUTER_GATEWAY_TOKEN": "env-token",
                "CC_ROUTER_SUBSCRIPTION_AUTH_FILE": tempRoot.appendingPathComponent("auth.json").path,
            ],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        #expect(configuration.host == "127.0.0.2")
        #expect(configuration.port == 4999)
        #expect(configuration.gatewayAuthToken == "env-token")
        #expect(configuration.subscriptionAuthFilePath.hasSuffix("/auth.json"))
        #expect(configuration.claudeEnvironmentSnippet.contains("ANTHROPIC_AUTH_TOKEN=env-token"))
    }

    @Test
    func savePersistsUpdatedConfigurationValues() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let initial = store.loadOrCreate()
        let updated = RouterConfiguration(
            host: "127.0.0.9",
            port: 4988,
            healthPath: initial.healthPath,
            messagesPath: initial.messagesPath,
            countTokensPath: initial.countTokensPath,
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.5",
            advisorModel: "gpt-5.5",
            gatewayAuthToken: initial.gatewayAuthToken,
            gatewayAuthHeader: initial.gatewayAuthHeader,
            subscriptionAuthFilePath: tempRoot.appendingPathComponent("auth-2.json").path,
            subscriptionAuthBookmarkData: Data("bookmark".utf8),
            configurationPath: initial.configurationPath,
            configurationWarning: initial.configurationWarning
        )

        let saved = store.save(configuration: updated)

        #expect(saved.host == "127.0.0.9")
        #expect(saved.port == 4988)
        #expect(saved.executorModel == "gpt-5.5")
        #expect(saved.advisorModel == "gpt-5.5")
        #expect(saved.subscriptionAuthFilePath.hasSuffix("/auth-2.json"))
        #expect(saved.subscriptionAuthBookmarkData == Data("bookmark".utf8))
    }

    @Test
    func saveWithRoutingTablePersistsExpectedRules() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let initial = store.loadOrCreate()
        let table = ModelRoutingTable(
            rules: [
                ModelRoutingRule(
                    match: "sonnet",
                    route: ModelRoute(upstreamModel: "gpt-5.4-mini", reasoningEffort: "high", textVerbosity: "medium")
                ),
            ],
            fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
        )
        let updated = RouterConfiguration(
            host: initial.host, port: initial.port,
            healthPath: initial.healthPath, messagesPath: initial.messagesPath,
            countTokensPath: initial.countTokensPath, responsesURL: initial.responsesURL,
            routingTable: table,
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: initial.gatewayAuthToken, gatewayAuthHeader: initial.gatewayAuthHeader,
            subscriptionAuthFilePath: initial.subscriptionAuthFilePath,
            subscriptionAuthBookmarkData: nil,
            configurationPath: initial.configurationPath,
            configurationWarning: initial.configurationWarning
        )

        let saved = store.save(configuration: updated)
        let reloaded = store.loadOrCreate()

        #expect(saved.routingTable.rules.count == 1)
        #expect(saved.routingTable.rules.first?.match == "sonnet")
        #expect(reloaded.routingTable.resolve(for: "claude-sonnet-4-6").upstreamModel == "gpt-5.4-mini")
        #expect(reloaded.advisorRoute.upstreamModel == "gpt-5.4")
    }

    @Test
    func containerizedHomeDefaultsBackToRealUserAuthPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let containerizedHome = URL(
            fileURLWithPath: "/Users/tester/Library/Containers/com.90percent.ModelBridge/Data",
            isDirectory: true
        )
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],
            fileManager: .default,
            homeDirectoryURL: containerizedHome
        )

        let configuration = store.loadOrCreate()

        #expect(
            configuration.subscriptionAuthFilePath
                == UserHomeResolver.defaultSubscriptionAuthFilePath(
                    fallbackHomeDirectoryURL: containerizedHome
                )
        )
        #expect(configuration.configurationWarning?.contains("App Sandbox") == true)
    }

    @Test
    func containerizedStoredAuthPathIsNormalizedBackToRealUserHome() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        let containerizedHome = URL(
            fileURLWithPath: "/Users/tester/Library/Containers/com.90percent.ModelBridge/Data",
            isDirectory: true
        )
        let legacyStoredPath = containerizedHome.appendingPathComponent(".codex/auth.json").path
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("{\"subscriptionAuthFilePath\":\"\(legacyStoredPath)\"}".utf8)
            .write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: containerizedHome
        )

        let configuration = store.loadOrCreate()

        #expect(configuration.subscriptionAuthFilePath != legacyStoredPath)
        #expect(
            configuration.subscriptionAuthFilePath
                == UserHomeResolver.defaultSubscriptionAuthFilePath(
                    fallbackHomeDirectoryURL: containerizedHome
                )
        )
    }
}
