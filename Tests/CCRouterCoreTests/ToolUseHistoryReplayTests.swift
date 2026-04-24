import Foundation
@testable import CCRouterCore
import Testing

// MARK: - ToolUseHistoryReplayTests

/// Tests for IRResponsesCodec.encodeFullHistory, covering temporal ordering of
/// message-nested blocks and top-level replay items.
///
/// Covers:
/// - encodeFullHistory: text-only / tool_use-only baselines
/// - encodeFullHistory: interleaving of [text, tool_use] in assistant messages
/// - encodeFullHistory: interleaving of [thinking, text, tool_use] (core replay scenario)
/// - encodeFullHistory: thinking with nil encrypted_content dropped ([D-006])
/// - encodeFullHistory: user tool_result encoding (function_call_output)
/// - encodeFullHistory: multi-turn ordering across message boundaries
/// - encodeFullHistory: role guard rules (thinking/tool_use in user role → drop)
/// - encodeFullHistory: summary list shape in reasoning items
struct ToolUseHistoryReplayTests {

    // MARK: encodeFullHistory baselines

    @Test func encodeFullHistory_assistantTextOnly_producesMessageItem() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [.text("Hello world")])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let msg = items[0].objectValue else {
            Issue.record("Expected message item")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "assistant")
        // Upstream rejects input_text on assistant-role message content; must be output_text.
        #expect(msg.array("content")?[0].objectValue?.string("type") == "output_text")
        #expect(msg.array("content")?[0].objectValue?.string("text") == "Hello world")
    }

    @Test func encodeFullHistory_assistantToolUseOnly_producesFunctionCall() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "call_1", name: "Bash", input: JSONObject.from(["command": .string("ls")]))
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let fc = items[0].objectValue else {
            Issue.record("Expected function_call item")
            return
        }
        #expect(fc.string("type") == "function_call")
        #expect(fc.string("call_id") == "call_1")
        #expect(fc.string("name") == "Bash")
    }

    @Test func encodeFullHistory_assistantTextAndToolUse_producesMessageThenFunctionCall() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .text("Let me run that"),
                .toolUse(id: "call_2", name: "Bash", input: JSONObject.from(["command": .string("pwd")]))
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // text → message item, tool_use → function_call; two separate items
        #expect(items.count == 2)

        guard let msg = items[0].objectValue else {
            Issue.record("Expected message item at index 0")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "assistant")
        // Upstream rejects input_text on assistant-role message content; must be output_text.
        #expect(msg.array("content")?[0].objectValue?.string("type") == "output_text")
        #expect(msg.array("content")?[0].objectValue?.string("text") == "Let me run that")

        guard let fc = items[1].objectValue else {
            Issue.record("Expected function_call item at index 1")
            return
        }
        #expect(fc.string("type") == "function_call")
        #expect(fc.string("call_id") == "call_2")
    }

    // MARK: encodeFullHistory — interleaving core scenario

    @Test func encodeFullHistory_assistantThinkingTextToolUse_producesReasoningThenMessageThenFunctionCall() {
        let encrypted = Data("thinking-bytes".utf8)
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .thinking(encryptedContent: encrypted, summary: "I should run the command"),
                .text("Here it is"),
                .toolUse(id: "call_3", name: "Bash", input: JSONObject.from(["command": .string("date")]))
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // thinking → reasoning (top-level), text → message, tool_use → function_call
        #expect(items.count == 3)

        // Item 0: top-level reasoning
        guard let reasoning = items[0].objectValue else {
            Issue.record("Expected reasoning item at index 0")
            return
        }
        #expect(reasoning.string("type") == "reasoning")
        #expect(reasoning.string("encrypted_content") == encrypted.base64EncodedString())
        guard let summaryArray = reasoning.array("summary") else {
            Issue.record("Expected summary array in reasoning item")
            return
        }
        #expect(summaryArray.count == 1)
        #expect(summaryArray[0].objectValue?.string("type") == "summary_text")
        #expect(summaryArray[0].objectValue?.string("text") == "I should run the command")

        // Item 1: message with text
        guard let msg = items[1].objectValue else {
            Issue.record("Expected message item at index 1")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "assistant")
        #expect(msg.array("content")?[0].objectValue?.string("text") == "Here it is")

        // Item 2: function_call
        guard let fc = items[2].objectValue else {
            Issue.record("Expected function_call item at index 2")
            return
        }
        #expect(fc.string("type") == "function_call")
        #expect(fc.string("call_id") == "call_3")
    }

    @Test func encodeFullHistory_assistantThinkingWithNilEncryptedContent_isDropped() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .thinking(encryptedContent: nil, summary: "orphan summary"),
                .text("Done"),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // thinking with nil encrypted_content must be dropped per [D-006];
        // only the text message item should appear.
        #expect(items.count == 1)
        guard let msg = items[0].objectValue else {
            Issue.record("Expected message item")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "assistant")
        // No reasoning item in the output
        let hasReasoning = items.contains { $0.objectValue?.string("type") == "reasoning" }
        #expect(hasReasoning == false)
    }

    // MARK: encodeFullHistory — user role tool results

    @Test func encodeFullHistory_userToolResult_producesFunctionCallOutput() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_1", content: [.text("Tool ran successfully")])
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let fco = items[0].objectValue else {
            Issue.record("Expected function_call_output item")
            return
        }
        #expect(fco.string("type") == "function_call_output")
        #expect(fco.string("call_id") == "call_1")
        #expect(fco.string("output") == "Tool ran successfully")
    }

    @Test func encodeFullHistory_userMultipleToolResults_producesMultipleOutputs() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_a", content: [.text("Result A")]),
                .toolResult(toolUseID: "call_b", content: [.text("Result B")]),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 2)
        #expect(items[0].objectValue?.string("type") == "function_call_output")
        #expect(items[0].objectValue?.string("call_id") == "call_a")
        #expect(items[1].objectValue?.string("type") == "function_call_output")
        #expect(items[1].objectValue?.string("call_id") == "call_b")
    }

    // MARK: encodeFullHistory — multi-turn ordering

    @Test func encodeFullHistory_multiTurnConversation_ordersItemsAcrossMessages() {
        let encrypted = Data("think".utf8)
        let messages: [IRMessage] = [
            // Turn 1: user text
            IRMessage(role: "user", content: [.text("Run it")]),
            // Turn 2: assistant thinking + text + tool_use
            IRMessage(role: "assistant", content: [
                .thinking(encryptedContent: encrypted, summary: "Running command"),
                .text("Here we go"),
                .toolUse(id: "call_1", name: "Bash", input: JSONObject.from(["command": .string("true")])),
            ]),
            // Turn 3: user tool_result
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_1", content: [.text("done")])
            ]),
            // Turn 4: assistant text
            IRMessage(role: "assistant", content: [.text("Finished")]),
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // Expected order:
        // 1. message (user text)
        // 2. reasoning (top-level thinking)
        // 3. message (assistant text)
        // 4. function_call (tool_use)
        // 5. function_call_output (tool_result)
        // 6. message (assistant text "Finished")
        #expect(items.count == 6)

        #expect(items[0].objectValue?.string("type") == "message")
        #expect(items[0].objectValue?.string("role") == "user")
        #expect(items[0].objectValue?.array("content")?[0].objectValue?.string("text") == "Run it")

        #expect(items[1].objectValue?.string("type") == "reasoning")

        #expect(items[2].objectValue?.string("type") == "message")
        #expect(items[2].objectValue?.string("role") == "assistant")
        #expect(items[2].objectValue?.array("content")?[0].objectValue?.string("text") == "Here we go")

        #expect(items[3].objectValue?.string("type") == "function_call")
        #expect(items[3].objectValue?.string("call_id") == "call_1")

        #expect(items[4].objectValue?.string("type") == "function_call_output")
        #expect(items[4].objectValue?.string("call_id") == "call_1")

        #expect(items[5].objectValue?.string("type") == "message")
        #expect(items[5].objectValue?.string("role") == "assistant")
        #expect(items[5].objectValue?.array("content")?[0].objectValue?.string("text") == "Finished")
    }

    // MARK: encodeFullHistory — role guard rules

    @Test func encodeFullHistory_thinkingInUserRole_isDropped() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .thinking(encryptedContent: Data("bad".utf8), summary: "thinking in user role"),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // thinking in user role must be dropped silently
        #expect(items.isEmpty)
    }

    @Test func encodeFullHistory_toolUseInUserRole_isDropped() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolUse(id: "call_x", name: "Bash", input: JSONObject())
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        // tool_use in user role must be dropped silently
        #expect(items.isEmpty)
    }

    @Test func encodeFullHistory_preservesMessageRole() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [.text("Hello")]),
            IRMessage(role: "assistant", content: [.text("Hi there")]),
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 2)
        #expect(items[0].objectValue?.string("role") == "user")
        #expect(items[1].objectValue?.string("role") == "assistant")
    }

    @Test func encodeFullHistory_emptyMessageList_producesEmptyInput() {
        let items = IRResponsesCodec.encodeFullHistory([])
        #expect(items.isEmpty)
    }

    // MARK: encodeFullHistory — summary list shape regression (Task 3/Task 10 consistency)

    @Test func encodeFullHistory_assistantThinking_emitsSummaryAsList() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .thinking(encryptedContent: Data("enc".utf8), summary: "hello"),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let reasoning = items[0].objectValue else {
            Issue.record("Expected reasoning item")
            return
        }
        #expect(reasoning.string("type") == "reasoning")
        guard let summaryArray = reasoning.array("summary") else {
            Issue.record("Expected summary array")
            return
        }
        // summary must be a list of {type:"summary_text", text:"hello"}, not a plain string
        #expect(summaryArray.count == 1)
        #expect(summaryArray[0].objectValue?.string("type") == "summary_text")
        #expect(summaryArray[0].objectValue?.string("text") == "hello")
    }

    // MARK: Role-aware text encoding (Phase-3 runtime fix)

    /// Upstream /responses rejects messages where `role:"assistant"` content
    /// uses `type:"input_text"` — it requires `output_text` or `refusal`.
    /// Runtime verification caught this when a history-replay request with an
    /// assistant text block returned 400 "Invalid value: 'input_text'". This
    /// test locks the role-aware text type behavior in both encode paths.
    @Test func encodeFullHistory_userAndAssistantText_usesCorrectTextType() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [.text("question")]),
            IRMessage(role: "assistant", content: [.text("answer")]),
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 2)

        let userType = items[0].objectValue?.array("content")?[0].objectValue?.string("type")
        let assistantType = items[1].objectValue?.array("content")?[0].objectValue?.string("type")
        #expect(userType == "input_text")
        #expect(assistantType == "output_text")
    }

    @Test func encodeInputItems_assistantText_usesOutputText() {
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [.text("draft response")]),
        ]
        let items = IRResponsesCodec.encodeInputItems(messages)
        #expect(items.count == 1)
        #expect(items[0].objectValue?.array("content")?[0].objectValue?.string("type") == "output_text")
    }
}
