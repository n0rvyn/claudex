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
            configurationPath: initial.configurationPath,
            configurationWarning: initial.configurationWarning
        )

        let saved = store.save(configuration: updated)

        #expect(saved.host == "127.0.0.9")
        #expect(saved.port == 4988)
        #expect(saved.executorModel == "gpt-5.5")
        #expect(saved.advisorModel == "gpt-5.5")
        #expect(saved.subscriptionAuthFilePath.hasSuffix("/auth-2.json"))
    }
}
