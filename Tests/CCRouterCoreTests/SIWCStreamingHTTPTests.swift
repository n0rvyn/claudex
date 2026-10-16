import Foundation
import Network
import Testing
@testable import CCRouterCore

/// Uses the shipping HTTP server, URLSession byte parser and SIWC bridge.
/// Only the upstream provider and credentials are synthetic; both listeners
/// bind temporary loopback ports, never the user's active gateway port.
struct SIWCStreamingHTTPTests {
    private actor UpstreamLifetime {
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
    private struct Auth: SubscriptionSessionProviding {
        func loadCurrent() async throws -> SubscriptionCredentials {
            SubscriptionCredentials(accessToken: "offline-fixture", accountID: "offline-fixture")
        }
    }
    private struct Counter: AnthropicInputTokenCounting {
        func countInputTokens(for responsesPayload: JSONObject) async throws -> Int { 1 }
    }
    private func configuration(_ port: UInt16, root: URL) -> RouterConfiguration {
        RouterConfiguration(environment: ["CC_ROUTER_PORT": String(port),
            "CC_ROUTER_CONFIG_PATH": root.appendingPathComponent("config.json").path], homeDirectoryURL: root)
    }
    private func start(_ server: LocalHTTPServer) async throws {
        try server.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            switch server.listenerState {
            case .ready: return
            case .failed(let error): throw error
            default:
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    @Test(arguments: ["completed-open", "failed-empty", "failed-partial", "advisor-failed"])
    func realHTTPStreamHasProtocolOutcome(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-stream-http-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifetime = UpstreamLifetime()
        defer { Task { await lifetime.release() } }
        let upstreamPort = try reserveLoopbackPort()
        let upstream = LocalHTTPServer(configuration: configuration(upstreamPort, root: root)) { request in
            let payload = try? JSONDecoder().decode(JSONObject.self, from: request.body)
            let isAdvisor = payload?.array("tools")?.isEmpty == true
            return HTTPResponse(statusCode: 200, reasonPhrase: "OK", headers: ["Content-Type": "text/event-stream"], stream: { writer in
                func emit(_ json: String) async throws {
                    try await writer.write(Data(("data: " + json + "\n\n").utf8))
                }
                if mode == "advisor-failed", !isAdvisor {
                    try await emit(#"{"type":"response.output_item.done","item":{"type":"function_call","id":"advisor_item","call_id":"advisor_call","namespace":"claudex_advisor","name":"advisor","arguments":"{}"}}"#)
                    try await emit(#"{"type":"response.completed"}"#)
                } else if mode == "completed-open" {
                    try await emit(#"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"COMPLETE_HTTP_ANSWER"}]}}"#)
                    try await emit(#"{"type":"response.completed"}"#)
                } else {
                    if mode == "failed-partial" { try await emit(#"{"type":"response.output_text.delta","delta":"PARTIAL_HTTP_ANSWER"}"#) }
                    try await emit(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
                }
                // Keep transport open until the downstream request has finished.
                // This makes terminal-event verification independent of timing.
                await lifetime.wait()
            })
        }
        try await start(upstream)
        defer { upstream.stop() }
        let client = ResponsesClient(endpoint: URL(string: "http://127.0.0.1:\(upstreamPort)/v1/responses")!)
        let gatewayPort = try reserveLoopbackPort()
        let bridge = SIWCBridge(configuration: configuration(gatewayPort, root: root), auth: Auth(),
            client: client, counter: Counter(), replayStore: SIWCReplayStore(directory: root.appendingPathComponent("Replay")))
        let gateway = LocalHTTPServer(configuration: configuration(gatewayPort, root: root)) { request in
            await bridge.handleMessages(request)
        }
        try await start(gateway)
        defer { gateway.stop() }
        var wire = URLRequest(url: URL(string: "http://127.0.0.1:\(gatewayPort)/v1/messages")!)
        wire.timeoutInterval = 10
        wire.httpMethod = "POST"
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("isolated-http-fixture", forHTTPHeaderField: "X-Claude-Code-Session-Id")
        let tools = mode == "advisor-failed" ? #", "tools":[{"type":"advisor_20260301","name":"advisor","model":"fixture"}]"# : ""
        wire.httpBody = Data((#"{"model":"fixture","stream":true,"messages":[{"role":"user","content":"fixture"}]"# + tools + "}").utf8)
        let (bytes, response) = try await URLSession.shared.data(for: wire)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding: bytes, as: UTF8.self)
        if mode == "completed-open" {
            #expect(text.contains("COMPLETE_HTTP_ANSWER"))
            #expect(text.contains("event: message_stop"))
            #expect(!text.contains("event: error"))
        } else {
            #expect(text.contains("event: error"))
            #expect(text.contains("subscription_sharing_usage_limit_exceeded"))
            #expect(text.contains("api_error"))
            #expect(!text.contains("event: message_stop"))
            if mode == "failed-partial" { #expect(text.contains("PARTIAL_HTTP_ANSWER")) }
            let ledger = try String(contentsOf: root.appendingPathComponent("Replay/traffic.jsonl"), encoding: .utf8)
            let failures = ledger.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(JSONObject.self, from: Data($0.utf8))
            }.filter { $0.string("stage") == "model_failure" }
            #expect(failures.count == 1)
            #expect(failures.first?.string("error_code") == "subscription_sharing_usage_limit_exceeded")
            #expect(failures.first?.string("role") == (mode == "advisor-failed" ? "advisor" : "executor"))
            #expect(failures.first?.string("upstream_event") == "response.failed")
        }
    }
}
