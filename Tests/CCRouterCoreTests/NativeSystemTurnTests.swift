import Foundation
import Testing
@testable import CCRouterCore

struct NativeSystemTurnTests {
    let route = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low")
    let headers = ["anthropic-beta": [EffortPolicy.claudeCodeMessageBeta, EffortPolicy.systemMessageBeta, EffortPolicy.toolChangesBeta].joined(separator: ",")]
    func input(_ messages: String) throws -> AnthropicMessagesRequest {
        try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data((#"{"model":"claude","tools":[{"name":"Read","input_schema":{"type":"object"}}],"messages":"# + messages + "}").utf8))
    }
    @Test func textAndExplicitToolChangesPreserveInstructionPositionAndFinalAvailability() throws {
        let value = try input(#"[{"role":"user","content":"one"},{"role":"system","output_config":{"effort":"low"},"content":[{"type":"text","text":"Keep workspace rules"},{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read"}},{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Write","description":"fixture","input_schema":{"type":"object"}}}}]}]"#)
        try SIWCBridge.validateSystemTurns(value.messages, headers: headers)
        #expect(try EffortPolicy.clientEffort(value, headers: headers) == "low")
        let payload = try SIWCBridge.payload(value, route: route)
        let items = try #require(payload.array("input"))
        #expect(items.count == 2)
        #expect(payload.string("instructions") == "")
        #expect(!items.contains { $0.objectValue?.string("role") == "system" })
        #expect(items[1].objectValue?.string("role") == "developer")
        #expect(items[1].objectValue?.array("content")?.first?.objectValue?.string("text") == "Keep workspace rules")
        #expect(payload.array("tools")?.first?.objectValue?.array("tools")?.compactMap { $0.objectValue?.string("name") } == ["Write"])
    }
    @Test func declaredReferencesCanRestoreRemovedToolsWithoutInventingSchema() throws {
        let value = try input(#"[{"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read"}},{"type":"tool_addition","tool":{"type":"tool_reference","name":"Read"}}]},{"role":"user","content":"one"}]"#)
        try SIWCBridge.validateSystemTurns(value.messages, headers: headers)
        #expect(try SIWCBridge.payload(value, route: route).array("tools")?.first?.objectValue?.array("tools")?.first?.objectValue?.string("name") == "Read")
        let unresolved = try input(#"[{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"Missing"}}]}]"#)
        #expect(throws: SIWCError.self) { try SIWCBridge.payload(unresolved, route: route) }
    }
    @Test func temporarySystemTextExpiresOnlyAtNextUserAndRetainsFingerprintBoundary() throws {
        let value = try input(#"[{"role":"user","content":"one"},{"role":"system","content":[{"type":"text","text":"temporary"}],"clear_at":"next_user_message"},{"role":"assistant","content":"answer"},{"role":"user","content":"two"},{"role":"system","content":[{"type":"text","text":"current"}],"clear_at":"next_user_message"}]"#)
        try SIWCBridge.validateSystemTurns(value.messages, headers: headers)
        let payload = try SIWCBridge.payload(value, route: route)
        let texts = payload.array("input")?.flatMap { $0.objectValue?.array("content") ?? [] }.compactMap { $0.objectValue?.string("text") } ?? []
        #expect(!texts.contains("temporary"))
        #expect(texts.last == "current")
        #expect(payload.array("input")?.last?.objectValue?.string("role") == "developer")
        let plain = AnthropicMessage(role: "system", content: value.messages[1].content)
        #expect(SIWCBridge.fingerprint([plain]) != SIWCBridge.fingerprint([value.messages[1]]))
        #expect(throws: SIWCError.self) { try SIWCBridge.validateSystemTurns(value.messages, headers: [:]) }
    }
}
