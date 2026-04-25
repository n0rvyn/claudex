import Foundation
import Testing
import CCRouterCore

struct ClaudexTests {
    @Test
    func configurationStorePersistsGatewayToken() throws {
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
    func configurationStoreBuildsAnthropicSnippet() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: [
                "CC_ROUTER_CONFIG_PATH": configPath,
                "CC_ROUTER_GATEWAY_TOKEN": "env-token",
            ],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        #expect(configuration.claudeEnvironmentSnippet.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:4317"))
        #expect(configuration.claudeEnvironmentSnippet.contains("ANTHROPIC_AUTH_TOKEN=env-token"))
    }
}
