import Foundation
@testable import CCRouterCore
import Testing

// MARK: - ThinkingBlockEmissionTests

/// Tests for thinking block encoding/decoding, signature roundtrip, SSE streaming
/// emission, and reasoning.summary list shape coverage.
///
/// Covers:
/// - IRAnthropicCodec: encodeResponseBlock (signature field emission)
/// - IRAnthropicCodec: decodeRequestBlocks (signature → encryptedContent)
/// - IRResponsesCodec: decodeOutputItem (summary list flattening)
/// - IRResponsesCodec: encodeReplayBlocks (summary list emission)
/// - AnthropicBridge.makeResponsesPayload: reasoning.summary: auto
/// - AnthropicSSEEncoder: streaming thinking/signature delta methods
/// - AnthropicBridge.processUpstreamStream: reasoning_summary_* event handling
struct ThinkingBlockEmissionTests {

    // MARK: encodeResponseBlock

    @Test func encodeResponseBlock_thinkingWithEncryptedContent_emitsSignature() {
        let encrypted = Data("test-bytes".utf8)
        let block = IRBlock.thinking(encryptedContent: encrypted, summary: "summary-text")
        let encoded = IRAnthropicCodec.encodeResponseBlock(block)

        #expect(encoded != nil)
        guard let obj = encoded else { return }
        #expect(obj.string("type") == "thinking")
        #expect(obj.string("thinking") == "summary-text")
        #expect(obj.string("signature") == encrypted.base64EncodedString())
    }

    @Test func encodeResponseBlock_thinkingWithNilEncryptedContent_omitsSignature() {
        let block = IRBlock.thinking(encryptedContent: nil, summary: "summary-text")
        let encoded = IRAnthropicCodec.encodeResponseBlock(block)

        #expect(encoded != nil)
        guard let obj = encoded else { return }
        #expect(obj.string("type") == "thinking")
        #expect(obj.string("thinking") == "summary-text")
        // signature field must not be present when encryptedContent is nil
        #expect(encoded?.values["signature"] == nil)
    }

    @Test func encodeResponseBlock_thinkingWithEmptyEncryptedContent_omitsSignature() {
        let block = IRBlock.thinking(encryptedContent: Data(), summary: "summary-text")
        let encoded = IRAnthropicCodec.encodeResponseBlock(block)

        #expect(encoded != nil)
        guard let obj = encoded else { return }
        #expect(obj.string("type") == "thinking")
        // signature field must not be present when encryptedContent is empty
        #expect(encoded?.values["signature"] == nil)
    }

    // MARK: decodeRequestBlocks

    @Test func decodeRequestBlocks_thinkingWithSignature_decodesToEncryptedContent() {
        let rawBytes = Data("test".utf8)
        let b64 = rawBytes.base64EncodedString()
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("thinking"),
                "thinking": .string("s"),
                "signature": .string(b64),
            ])
        ])
        #expect(blocks.count == 1)
        if case .thinking(let enc, let summary) = blocks[0] {
            #expect(enc == rawBytes)
            #expect(summary == "s")
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func decodeRequestBlocks_thinkingWithoutSignature_producesNilEncryptedContent() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("thinking"),
                "thinking": .string("s"),
            ])
        ])
        #expect(blocks.count == 1)
        if case .thinking(let enc, let summary) = blocks[0] {
            #expect(enc == nil)
            #expect(summary == "s")
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func decodeRequestBlocks_thinkingInvalidSignatureBase64_producesNilEncryptedContent() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("thinking"),
                "thinking": .string("s"),
                "signature": .string("not-base64!@#"),
            ])
        ])
        #expect(blocks.count == 1)
        if case .thinking(let enc, let summary) = blocks[0] {
            #expect(enc == nil)
            #expect(summary == "s")
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    // MARK: Roundtrip

    @Test func roundtrip_encryptedContentPreservedThroughEncodeDecode() {
        // 256 bytes of random-ish data
        var rawBytes = Data(count: 256)
        for i in 0..<256 { rawBytes[i] = UInt8((i * 17 + 31) & 0xFF) }

        // Encode via IRAnthropicCodec (IR → Anthropic wire)
        let irBlock = IRBlock.thinking(encryptedContent: rawBytes, summary: "roundtrip-test")
        let encoded = IRAnthropicCodec.encodeResponseBlock(irBlock)
        #expect(encoded != nil)

        // Treat the encoded object as an inbound Anthropic request block and decode it
        let decodedBlocks = IRAnthropicCodec.decodeRequestBlocks([encoded!])
        #expect(decodedBlocks.count == 1)
        if case .thinking(let recoveredEnc, let summary) = decodedBlocks[0] {
            #expect(recoveredEnc == rawBytes)
            #expect(summary == "roundtrip-test")
        } else {
            Issue.record("Expected .thinking block after roundtrip")
        }
    }

    // MARK: makeResponsesPayload

    @Test func makeResponsesPayload_requestsReasoningSummaryAuto() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.4",
            advisorModel: "gpt-5.4",
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
        let mockStream = MockResponsesEventStream.textOnlyTurn(text: "Done")
        let mockClient = MockResponsesClient(streams: [mockStream])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )

        let httpRequest = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: try! JSONEncoder().encode(AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ))
        )
        let response = await bridge.handleMessages(httpRequest)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected streaming response")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let capturedRequests = await mockClient.capturedRequests
        #expect(capturedRequests.count == 1)
        let payload = capturedRequests[0]
        let reasoning = payload.object("reasoning")
        #expect(reasoning?.string("effort") != nil)
        #expect(reasoning?.string("summary") == "auto")
    
        }
    }

    @Test func makeResponsesPayload_includesOnlyEncryptedContent() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.4",
            advisorModel: "gpt-5.4",
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
        let mockStream = MockResponsesEventStream.textOnlyTurn(text: "Done")
        let mockClient = MockResponsesClient(streams: [mockStream])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )

        let httpRequest = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: try! JSONEncoder().encode(AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ))
        )
        let response = await bridge.handleMessages(httpRequest)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected streaming response")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let capturedRequests = await mockClient.capturedRequests
        #expect(capturedRequests.count == 1)
        let payload = capturedRequests[0]
        let include = payload.array("include")
        #expect(include?.count == 1)
        #expect(include?[0].stringValue == "reasoning.encrypted_content")
    
        }
    }


    // MARK: processUpstreamStream — summary streaming

    @Test func processUpstreamStream_summaryDeltaEvents_streamedAsThinkingDeltas() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Build a mock stream matching the probe-verified sequence:
        // reasoning_summary_part.added → reasoning_summary_text.delta("A") →
        // reasoning_summary_text.delta("B") → reasoning_summary_part.done →
        // output_item.done(reasoning with encrypted_content)
        let encryptedBytes = Data("probe-enc".utf8)
        let encBase64 = encryptedBytes.base64EncodedString()

        let mockStream = AsyncThrowingStream<JSONObject, Error> { continuation in
            continuation.yield(JSONObject.from(["type": .string("response.created")]))
            continuation.yield(JSONObject.from(["type": .string("response.reasoning_summary_part.added")]))
            continuation.yield(JSONObject.from([
                "type": .string("response.reasoning_summary_text.delta"),
                "delta": .string("A"),
            ]))
            continuation.yield(JSONObject.from([
                "type": .string("response.reasoning_summary_text.delta"),
                "delta": .string("B"),
            ]))
            continuation.yield(JSONObject.from(["type": .string("response.reasoning_summary_part.done")]))
            continuation.yield(JSONObject.from([
                "type": .string("response.output_item.done"),
                "output_index": .number(0),
                "item": .object(JSONObject.from([
                    "type": .string("reasoning"),
                    "encrypted_content": .string(encBase64),
                    "summary": .array([
                        .object(JSONObject.from(["type": .string("summary_text"), "text": .string("A")]))
                    ]),
                ])),
            ]))
            continuation.yield(JSONObject.from([
                "type": .string("response.completed"),
                "response": .object(JSONObject.from([
                    "id": .string("resp_1"),
                    "usage": .object(JSONObject.from([
                        "input_tokens": .number(10),
                        "output_tokens": .number(5),
                    ])),
                ])),
            ]))
            continuation.finish()
        }

        let writer = InMemoryBodyWriter()
        let encoder = AnthropicSSEEncoder(anthropicModel: "test", writer: writer)
        try await encoder.startMessage(initialInputTokens: 17)

        // Call processUpstreamStream indirectly via AnthropicBridge.runStreamingTurn
        let config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.4",
            advisorModel: "gpt-5.4",
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )

        let mockClient = MockResponsesClient(streams: [mockStream])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )

        let httpRequest = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: try! JSONEncoder().encode(AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ))
        )

        let response = await bridge.handleMessages(httpRequest)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected streaming response")
            return
        }
        try await producer(writer)
        try await encoder.finish(stopReasonHint: .endTurn)

        let frames = await writer.parseSSEFrames()
        let outerMessageStartUsage = frames.first { $0.data.string("type") == "message_start" }?
            .data.object("message")?
            .object("usage")?["input_tokens"]?
            .intValue
        #expect(outerMessageStartUsage == 17)

        // Merge top-level frame types and delta sub-types into a single temporal
        // sequence so order is assertable. For content_block_delta frames, use the
        // delta's `type` (thinking_delta / signature_delta) as the sequence token.
        let ordered: [String] = frames.compactMap { frame in
            let top = frame.data.string("type") ?? ""
            if top == "content_block_delta",
               let deltaType = frame.data.object("delta")?.string("type") {
                return deltaType
            }
            return top
        }

        let expected: [String] = [
            "message_start",
            "content_block_start",
            "thinking_delta",
            "thinking_delta",
            "signature_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ]
        // Bridge's inner encoder's frames must appear as a contiguous subsequence,
        // in this exact order. (The test-local outer encoder wraps the writer with
        // its own message_start/message_delta/message_stop; those are not under test.)
        let innerStart = ordered.firstIndex(of: "content_block_start").map { idx in
            max(0, idx - 1)  // include the message_start immediately preceding content_block_start
        }
        let innerSlice: [String]
        if let start = innerStart, start + expected.count <= ordered.count {
            innerSlice = Array(ordered[start..<(start + expected.count)])
        } else {
            innerSlice = []
        }
        #expect(innerSlice == expected)

        // signature_delta payload must carry the upstream encrypted_content verbatim.
        let signatureDeltaFrame = frames.first { $0.data.object("delta")?.string("type") == "signature_delta" }
        #expect(signatureDeltaFrame?.data.object("delta")?.string("signature") == encBase64)
    
        }
    }

    @Test func processUpstreamStream_reasoningItemWithoutSummaryStream_fallsBackToAtomic() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Simulate an older upstream that sends output_item.done(reasoning) without
        // emitting any reasoning_summary_part.* events. The bridge should fall back
        // to atomic emitThinkingBlock.
        let encryptedBytes = Data("fallback-enc".utf8)
        let encBase64 = encryptedBytes.base64EncodedString()

        let mockStream = AsyncThrowingStream<JSONObject, Error> { continuation in
            continuation.yield(JSONObject.from(["type": .string("response.created")]))
            continuation.yield(JSONObject.from([
                "type": .string("response.output_item.done"),
                "output_index": .number(0),
                "item": .object(JSONObject.from([
                    "type": .string("reasoning"),
                    "encrypted_content": .string(encBase64),
                    "summary": .array([]),
                ])),
            ]))
            continuation.yield(JSONObject.from([
                "type": .string("response.completed"),
                "response": .object(JSONObject.from([
                    "id": .string("resp_1"),
                    "usage": .object(JSONObject.from([
                        "input_tokens": .number(10),
                        "output_tokens": .number(5),
                    ])),
                ])),
            ]))
            continuation.finish()
        }

        let writer = InMemoryBodyWriter()
        let encoder = AnthropicSSEEncoder(anthropicModel: "test", writer: writer)
        try await encoder.startMessage(initialInputTokens: 1)

        let config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.4",
            advisorModel: "gpt-5.4",
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )

        let mockClient = MockResponsesClient(streams: [mockStream])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )

        let httpRequest = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: try! JSONEncoder().encode(AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ))
        )

        let response = await bridge.handleMessages(httpRequest)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected streaming response")
            return
        }
        try await producer(writer)
        try await encoder.finish(stopReasonHint: .endTurn)

        let frames = await writer.parseSSEFrames()
        let frameTypes = frames.map { $0.data.string("type") ?? "" }

        // Fallback path: content_block_start(thinking) → content_block_stop
        // No thinking_delta or signature_delta streaming events expected.
        #expect(frameTypes.contains("content_block_start"))
        let startBlock = frames.first { $0.data.string("type") == "content_block_start" }
        let contentBlockType = startBlock?.data.object("content_block")?.string("type")
        #expect(contentBlockType == "thinking")
        #expect(!frameTypes.contains("content_block_delta"))
        #expect(frameTypes.contains("content_block_stop"))
        #expect(frameTypes.contains("message_stop"))
    
        }
    }


    // MARK: thinking enabled request field (Decision C regression)

    @Test func thinkingEnabledRequestField_doesNotOverrideRoute() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Verify that an incoming request with thinking: {type: "enabled", ...}
        // does not override the reasoning.effort sourced from the routing table.
        let config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            executorModel: "gpt-5.4",
            advisorModel: "gpt-5.4",
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )

        let mockStream = MockResponsesEventStream.textOnlyTurn(text: "Done")
        let mockClient = MockResponsesClient(streams: [mockStream])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )

        // Request with thinking.enabled field
        let httpRequest = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: try! JSONEncoder().encode(AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
                system: nil,
                tools: nil,
                thinking: JSONObject.from(["type": .string("enabled"), "budget_tokens": .number(10000)]),
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ))
        )

        let response = await bridge.handleMessages(httpRequest)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected streaming response")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let capturedRequests = await mockClient.capturedRequests
        #expect(capturedRequests.count == 1)
        let payload = capturedRequests[0]
        let reasoning = payload.object("reasoning")
        // Effort must not be nil/empty (comes from route)
        #expect(reasoning?.string("effort") != nil)
        // The request's thinking field must NOT appear in the payload
        #expect(payload.values["thinking"] == nil)
    
        }
    }


    // MARK: decodeOutputItem — summary list flattening

    @Test func decodeOutputItem_reasoningWithSummaryAsList_flattensToString() {
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(Data("abc".utf8).base64EncodedString()),
            "summary": .array([
                .object(JSONObject.from(["type": .string("summary_text"), "text": .string("A")])),
                .object(JSONObject.from(["type": .string("summary_text"), "text": .string("B")])),
            ]),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        #expect(block != nil)
        if case .thinking(let enc, let summary) = block! {
            #expect(summary == "A\n\nB")
            #expect(enc == Data("abc".utf8))
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func decodeOutputItem_reasoningWithSummaryAsString_passesThrough() {
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(Data("xyz".utf8).base64EncodedString()),
            "summary": .string("hello"),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        #expect(block != nil)
        if case .thinking(let enc, let summary) = block! {
            #expect(summary == "hello")
            #expect(enc == Data("xyz".utf8))
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    @Test func decodeOutputItem_reasoningWithEmptySummaryList_returnsNilSummary() {
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(Data("abc".utf8).base64EncodedString()),
            "summary": .array([]),
        ])
        let block = IRResponsesCodec.decodeOutputItem(item)
        #expect(block != nil)
        if case .thinking(let enc, let summary) = block! {
            #expect(summary == nil)
            #expect(enc == Data("abc".utf8))
        } else {
            Issue.record("Expected .thinking block")
        }
    }

    // MARK: encodeReplayBlocks — summary list emission

    @Test func encodeReplayBlocks_emitsSummaryAsSingleElementList() {
        let block = IRBlock.thinking(encryptedContent: Data("test".utf8), summary: "hello")
        let items = IRResponsesCodec.encodeReplayBlocks([block])
        #expect(items.count == 1)
        guard let reasoning = items[0].objectValue else {
            Issue.record("Expected reasoning item")
            return
        }
        #expect(reasoning.string("type") == "reasoning")
        #expect(reasoning.string("encrypted_content") == Data("test".utf8).base64EncodedString())
        guard let summaryArray = reasoning.array("summary") else {
            Issue.record("Expected summary array")
            return
        }
        #expect(summaryArray.count == 1)
        #expect(summaryArray[0].objectValue?.string("type") == "summary_text")
        #expect(summaryArray[0].objectValue?.string("text") == "hello")
    }

    @Test func encodeReplayBlocks_emptySummary_emitsEmptyList() {
        let block = IRBlock.thinking(encryptedContent: Data("test".utf8), summary: nil)
        let items = IRResponsesCodec.encodeReplayBlocks([block])
        #expect(items.count == 1)
        guard let reasoning = items[0].objectValue else {
            Issue.record("Expected reasoning item")
            return
        }
        guard let summaryArray = reasoning.array("summary") else {
            Issue.record("Expected summary array")
            return
        }
        #expect(summaryArray.isEmpty)
    }

    // MARK: URL-safe base64 tolerance (Phase-3 runtime fix)

    /// Upstream /responses emits `encrypted_content` as URL-safe base64
    /// (`-`/`_` instead of `+`/`/`). Runtime verification caught that Swift's
    /// strict Data(base64Encoded:) returned nil for real upstream values,
    /// silently dropping signature_delta emission. This test locks the
    /// URL-safe decode behavior via decodeTolerantBase64.
    @Test func decodeOutputItem_reasoningWithUrlSafeBase64_decodesEncryptedContent() {
        let original = Data((0..<200).map { UInt8($0 % 256) })
        // Standard base64 → URL-safe by remapping + → -, / → _ (no stripping of =).
        let urlSafe = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let item = JSONObject.from([
            "type": .string("reasoning"),
            "encrypted_content": .string(urlSafe),
            "summary": .array([]),
        ])
        guard let ir = IRResponsesCodec.decodeOutputItem(item) else {
            Issue.record("Expected IRBlock from reasoning item")
            return
        }
        guard case .thinking(let enc, _) = ir else {
            Issue.record("Expected .thinking IR block")
            return
        }
        #expect(enc == original)
    }

    @Test func decodeTolerantBase64_acceptsStandardAndUrlSafeAlphabets() {
        let payload = Data([0xfb, 0xff, 0xfe, 0x00, 0xa1, 0xb2, 0xc3])
        let std = payload.base64EncodedString()
        let urlSafe = std
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        #expect(IRResponsesCodec.decodeTolerantBase64(std) == payload)
        #expect(IRResponsesCodec.decodeTolerantBase64(urlSafe) == payload)
        // Whitespace and newlines tolerated.
        let withWS = std.enumerated().map { idx, ch in idx % 32 == 0 ? "\n\(ch)" : String(ch) }.joined()
        #expect(IRResponsesCodec.decodeTolerantBase64(withWS) == payload)
    }
}
