import Foundation
@testable import CCRouterCore
import Testing

// MARK: - Direction A: Anthropic request blocks → IR

struct IRBlockConversionTests {

    // MARK: Direction A

    @Test func anthropicTextBlockDecodesToIRText() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from(["type": .string("text"), "text": .string("hello")])
        ])
        #expect(blocks == [.text("hello")])
    }

    @Test func anthropicImageBase64DecodesToIRImage() {
        // 4 bytes: PNG magic header fragment
        let rawBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let b64 = rawBytes.base64EncodedString()
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("image"),
                "source": .object(JSONObject.from([
                    "type": .string("base64"),
                    "media_type": .string("image/png"),
                    "data": .string(b64),
                ])),
            ])
        ])
        #expect(blocks.count == 1)
        if case .image(let decodedData, let mediaType) = blocks[0] {
            #expect(decodedData.count == 4)
            #expect(decodedData == rawBytes)
            #expect(mediaType == "image/png")
        } else {
            Issue.record("Expected .image block")
        }
    }

    @Test func anthropicToolUseDecodesToIRToolUse() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("tool_use"),
                "id": .string("toolu_1"),
                "name": .string("Bash"),
                "input": .object(JSONObject.from(["command": .string("true")])),
            ])
        ])
        #expect(blocks.count == 1)
        if case .toolUse(let id, let name, let input) = blocks[0] {
            #expect(id == "toolu_1")
            #expect(name == "Bash")
            #expect(input["command"]?.stringValue == "true")
        } else {
            Issue.record("Expected .toolUse block")
        }
    }

    @Test func anthropicToolResultWithArrayContentDecodesToIRToolResult() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("tool_result"),
                "tool_use_id": .string("toolu_1"),
                "content": .array([
                    .object(JSONObject.from([
                        "type": .string("text"),
                        "text": .string("ok"),
                    ]))
                ]),
            ])
        ])
        #expect(blocks.count == 1)
        if case .toolResult(let toolUseID, let content) = blocks[0] {
            #expect(toolUseID == "toolu_1")
            #expect(content == [.text("ok")])
        } else {
            Issue.record("Expected .toolResult block")
        }
    }

    @Test func anthropicToolResultWithStringContentDecodesToIRToolResultWithSingleText() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("tool_result"),
                "tool_use_id": .string("toolu_1"),
                "content": .string("plain string"),
            ])
        ])
        #expect(blocks.count == 1)
        if case .toolResult(let toolUseID, let content) = blocks[0] {
            #expect(toolUseID == "toolu_1")
            #expect(content == [.text("plain string")])
        } else {
            Issue.record("Expected .toolResult block")
        }
    }

    @Test func anthropicThinkingBlockDecodesToIRThinking() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("thinking"),
                "thinking": .string("reasoning text"),
            ])
        ])
        #expect(blocks.count == 1)
        if case .thinking(let enc, let summary) = blocks[0] {
            #expect(enc == nil)
            #expect(summary == "reasoning text")
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func unknownBlockTypeIsDropped() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from(["type": .string("custom_foo"), "value": .string("bar")])
        ])
        #expect(blocks.isEmpty)
    }

    // MARK: Direction B: IR → /responses input items

    @Test func irUserTextBecomesInputTextItem() {
        let message = IRMessage(role: "user", content: [.text("hi")])
        let items = IRResponsesCodec.encodeInputItems([message])
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        #expect(obj.string("type") == "message")
        #expect(obj.string("role") == "user")
        let content = obj.array("content")
        #expect(content?.count == 1)
        #expect(content?[0].objectValue?.string("type") == "input_text")
        #expect(content?[0].objectValue?.string("text") == "hi")
    }

    @Test func irToolUseEncodedViaEncodeReplayBlocks() {
        let blocks = [IRBlock.toolUse(
            id: "toolu_1",
            name: "Bash",
            input: JSONObject(["command": .string("true")])
        )]
        let items = IRResponsesCodec.encodeReplayBlocks(blocks)
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        #expect(obj.string("type") == "function_call")
        #expect(obj.string("call_id") == "toolu_1")
        #expect(obj.string("name") == "Bash")
        #expect(obj.string("arguments")?.contains("command") == true)
    }

    @Test func irThinkingEncodedViaEncodeReplayBlocks() {
        let encContent = Data([0x01, 0x02])
        let blocks: [IRBlock] = [.thinking(encryptedContent: encContent, summary: "thought")]
        let items = IRResponsesCodec.encodeReplayBlocks(blocks)
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        #expect(obj.string("type") == "reasoning")
        // summary emitted as list of {type:"summary_text", text:...} per Task 3 / probe Row F
        guard let summaryArray = obj.array("summary"), summaryArray.count == 1,
              let first = summaryArray[0].objectValue,
              first.string("type") == "summary_text",
              first.string("text") == "thought" else {
            Issue.record("Expected summary as single-element list of {type:summary_text, text:thought}")
            return
        }
        // encrypted_content should be base64 of 0x0102
        #expect(obj.string("encrypted_content") == encContent.base64EncodedString())
    }

    @Test func irToolResultEncodedViaEncodeToolResultOutputs() {
        let blocks = [IRBlock.toolResult(toolUseID: "toolu_1", content: [.text("ok")])]
        let items = IRResponsesCodec.encodeToolResultOutputs(blocks)
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        #expect(obj.string("type") == "function_call_output")
        #expect(obj.string("call_id") == "toolu_1")
        #expect(obj.string("output") == "ok")
    }

    // MARK: Direction C: /responses output item → IR → Anthropic wire

    @Test func responsesMessageItemDecodesToIRText() {
        let item = JSONObject.from([
            "type": .string("message"),
            "content": .array([
                .object(JSONObject.from([
                    "type": .string("output_text"),
                    "text": .string("reply"),
                ]))
            ]),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        #expect(block == .text("reply"))
    }

    @Test func responsesFunctionCallDecodesToIRToolUse() {
        let item = JSONObject.from([
            "type": .string("function_call"),
            "call_id": .string("call_1"),
            "name": .string("Bash"),
            "arguments": .string("{}"),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        if case .toolUse(let id, let name, let input) = block {
            #expect(id == "call_1")
            #expect(name == "Bash")
            #expect(input.values.isEmpty)
        } else {
            Issue.record("Expected .toolUse block")
        }
    }

    @Test func responsesFunctionCallWithEmptyArgumentsStringDecodes() {
        // Empty string
        let item1 = JSONObject.from([
            "type": .string("function_call"),
            "call_id": .string("c1"),
            "name": .string("T"),
            "arguments": .string(""),
        ])
        if case .toolUse(_, _, let input) = IRResponsesCodec.decodeOutputItem(item1) {
            #expect(input.values.isEmpty)
        } else {
            Issue.record("Expected .toolUse for empty string")
        }

        // Invalid JSON
        let item2 = JSONObject.from([
            "type": .string("function_call"),
            "call_id": .string("c2"),
            "name": .string("T"),
            "arguments": .string("not valid json"),
        ])
        if case .toolUse(_, _, let input) = IRResponsesCodec.decodeOutputItem(item2) {
            #expect(input.values.isEmpty)
        } else {
            Issue.record("Expected .toolUse for invalid JSON")
        }

        // Array (not object)
        let item3 = JSONObject.from([
            "type": .string("function_call"),
            "call_id": .string("c3"),
            "name": .string("T"),
            "arguments": .string("[1,2]"),
        ])
        if case .toolUse(_, _, let input) = IRResponsesCodec.decodeOutputItem(item3) {
            #expect(input.values.isEmpty)
        } else {
            Issue.record("Expected .toolUse for array arguments")
        }
    }

    @Test func responsesReasoningItemDecodesToIRThinking() {
        let encContent = Data([0x01, 0x02])
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(encContent.base64EncodedString()),
            "summary": .string("summary text"),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        if case .thinking(let enc, let summary) = block {
            #expect(enc == encContent)
            #expect(summary == "summary text")
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func responsesReasoningDecodesAndEncodesBackToAnthropicThinking() {
        // upstream reasoning → IR → Anthropic wire
        // When encryptedContent is non-nil, signature is now emitted (Task 4).
        let encContent = Data([0x01, 0x02])
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(encContent.base64EncodedString()),
            "summary": .string("summary text"),
        ])
        guard let ir = IRResponsesCodec.decodeOutputItem(item) else {
            Issue.record("Expected IR block")
            return
        }
        guard let result = IRAnthropicCodec.encodeResponseBlock(ir) else {
            Issue.record("Expected encoded result")
            return
        }
        #expect(result.string("type") == "thinking")
        #expect(result.string("thinking") == "summary text")
        // Task 4: signature is emitted when encryptedContent is non-nil
        #expect(result.values["signature"] != nil)
        #expect(result.values["signature"] == .string(encContent.base64EncodedString()))
    }

    @Test func irTextEncodesToAnthropicContentBlock() {
        let result = IRAnthropicCodec.encodeResponseBlock(.text("hi"))
        #expect(result != nil)
        #expect(result?.string("type") == "text")
        #expect(result?.string("text") == "hi")
    }

    @Test func irToolUseEncodesToAnthropicContentBlock() {
        let ir = IRBlock.toolUse(
            id: "toolu_1",
            name: "Bash",
            input: JSONObject(["command": .string("true")])
        )
        let result = IRAnthropicCodec.encodeResponseBlock(ir)
        #expect(result != nil)
        #expect(result?.string("type") == "tool_use")
        #expect(result?.string("id") == "toolu_1")
        #expect(result?.string("name") == "Bash")
        #expect(result?.object("input") != nil)
    }
}
