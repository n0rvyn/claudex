import Foundation
import Testing
@testable import CCRouterCore

struct ClaudeConnectionSnippetTests {
    private func configuration(token: String) -> RouterConfiguration {
        let route = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low")
        return RouterConfiguration(host: "127.0.0.1", port: 4317, healthPath: "/health", messagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens", responsesURL: "https://example.invalid", routingTable: ModelRoutingTable(rules: [], fallback: route), advisorRoute: route, gatewayAuthToken: token, gatewayAuthHeader: "x-api-key", subscriptionAuthFilePath: "/tmp/fixture-not-read", configurationPath: "/tmp/fixture-not-read", configurationWarning: nil)
    }
    private func shell(_ script: String, environment: [String: String]) throws -> (Int32, Data) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = environment
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, bytes)
    }
    @Test func copiedExportsPreserveLiteralSyntheticTokenInChildProcess() throws {
        let token = #"fixture ' quote spaces $HOME $(printf injected) `printf injected` ; " double"# + "\nsecond line"
        let config = configuration(token: token)
        let script = config.claudeEnvironmentSnippet + "\n" + #"/bin/sh -c 'printf "%s\000%s\000" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN"'"# + "\n"
        let result = try shell(script, environment: [:])
        #expect(result.0 == 0)
        #expect(result.1 == Data((config.endpoint + "\0" + token + "\0").utf8))
    }
    @Test func optionalBareCheckUsesOnlyExportedFixtureAndAppEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = directory.appendingPathComponent("claude")
        try Data(#"""
#!/bin/sh
printf '%s\000%s\000' "$ANTHROPIC_BASE_URL" "$ANTHROPIC_API_KEY"
printf '%s\000' "$@"
"""#.utf8).write(to: mock)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let token = "fixture-only-'quoted"
        let config = configuration(token: token)
        #expect(!config.claudeConnectionCheckCommand.contains(token))
        let result = try shell(config.claudeEnvironmentSnippet + "\n" + config.claudeConnectionCheckCommand + "\n", environment: ["PATH": directory.path + ":/usr/bin:/bin"])
        #expect(result.0 == 0)
        let parts = String(decoding: result.1, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.prefix(2) == [config.endpoint, token])
        #expect(parts.contains("--bare"))
        #expect(parts.contains("low"))
        #expect(parts.contains("Reply exactly SMOKEOK."))
        let missing = try shell(config.claudeConnectionCheckCommand + "\n", environment: ["PATH": directory.path + ":/usr/bin:/bin"])
        #expect(missing.0 != 0)
        #expect(missing.1.isEmpty)
    }
}
