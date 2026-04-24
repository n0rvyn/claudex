import Foundation
@testable import CCRouterCore
import Testing

// MARK: - BridgeRegressionTests

/// Regression tests covering the two validated baseline paths from
/// docs/scheme3/01-validated-baseline.md §3.13 (Bash tool turn) and §3.14 (advisor bridge).
/// These tests use the mock helpers from MockResponsesEventStream and assert wire-level
/// SSE frame shapes that match the Phase 0 baseline.
struct BridgeRegressionTests {

    // MARK: - Shared test configuration

    private static let testConfig = RouterConfiguration(
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

    private static let testCredentials = SubscriptionCredentials(
        accessToken: "test-token",
        accountID: "test-account"
    )

    // MARK: - Helpers

    /// Wraps an AnthropicMessagesRequest in an HTTPRequest body.
    private static func makeHTTPRequest(
        body: AnthropicMessagesRequest,
        extraHeaders: [String: String] = [:]
    ) -> HTTPRequest {
        let bodyData = try! JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: extraHeaders.merging(["content-type": "application/json"]) { _, new in new },
            body: bodyData
        )
    }

    private static func makeBashTool(
        description: String = "Run a bash command",
        includeCWD: Bool = false
    ) -> JSONObject {
        var properties = JSONObject.from([
            "command": .object(JSONObject.from(["type": .string("string")])),
        ])
        if includeCWD {
            properties["cwd"] = .object(JSONObject.from(["type": .string("string")]))
        }
        return JSONObject.from([
            "type": .string("function"),
            "name": .string("Bash"),
            "description": .string(description),
            "input_schema": .object(JSONObject.from([
                "type": .string("object"),
                "properties": .object(properties),
            ])),
        ])
    }

    private static func makeSkillTool() -> JSONObject {
        JSONObject.from([
            "type": .string("function"),
            "name": .string("Skill"),
            "description": .string("Load a skill by name"),
            "input_schema": .object(JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "skill": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])),
        ])
    }

    private static func makeAdvisorTool() -> JSONObject {
        JSONObject.from(["type": .string("advisor_20260301")])
    }

    private static func toolNames(in payload: JSONObject) -> [String] {
        (payload.array("tools") ?? [])
            .compactMap(\.objectValue)
            .compactMap { $0.string("name") }
    }

    /// Builds a minimal Bash tool-use request.
    private static func makeBashRequest(
        toolUseID: String? = nil,
        tool: JSONObject? = nil
    ) -> AnthropicMessagesRequest {
        var content: [JSONObject] = [
            JSONObject.from(["type": .string("text"), "text": .string("Run it")]),
        ]
        if let tid = toolUseID {
            content.append(JSONObject.from([
                "type": .string("tool_result"),
                "tool_use_id": .string(tid),
                "content": .string("success"),
            ]))
        }

        let bashTool = tool ?? makeBashTool()

        return AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: content)],
            system: nil,
            tools: [bashTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    /// Builds a continuation request with configurable tool ids and tool list presence.
    private static func makeBashContinuationRequest(
        toolUseID: String,
        tools: [JSONObject]? = nil
    ) -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(toolUseID),
                        "content": .string("success"),
                    ]),
                ]),
            ],
            system: nil,
            tools: tools,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    private static func makeBashHistoryBackedContinuationRequest(
        toolUseID: String,
        tools: [JSONObject]? = nil
    ) -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string(toolUseID),
                        "name": .string("Bash"),
                        "input": .object(JSONObject.from(["command": .string("true")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(toolUseID),
                        "content": .string("success"),
                    ]),
                ]),
            ],
            system: nil,
            tools: tools,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    private static func makeRequest(
        messages: [AnthropicMessage],
        tools: [JSONObject]? = [makeBashTool()]
    ) -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: messages,
            system: nil,
            tools: tools,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    /// Builds an advisor tool request.
    private static func makeAdvisorRequest() -> AnthropicMessagesRequest {
        let advisorTool = JSONObject.from(["type": .string("advisor_20260301")])
        return AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("Advise me")]),
                ]),
            ],
            system: nil,
            tools: [advisorTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    private static func makeAnthropicWebSearchTool() -> JSONObject {
        JSONObject.from([
            "type": .string("web_search_20250305"),
            "name": .string("web_search"),
            "max_uses": .number(5),
            "allowed_domains": .array([.string("example.com")]),
        ])
    }

    private static func makeWebSearchRequest() -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("Search for ModelBridge competitors")]),
                ]),
            ],
            system: nil,
            tools: [makeAnthropicWebSearchTool()],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    // MARK: - §3.13: Bash tool turn (two rounds)

    /// Regression: a Bash tool-use turn followed by a tool_result continuation.
    ///
    /// Round 1: upstream returns function_call(name="Bash", arguments={"command":"true"}).
    /// Bridge stops with stop_reason="tool_use".
    ///
    /// Round 2: upstream returns text "Ran a minimal Bash command successfully."
    /// Bridge stops with stop_reason="end_turn".
    ///
    /// Critical assertion (S1 #4修订): the continuation payload sent to /responses
    /// contains only reasoning / function_call / function_call_output items
    /// (no text-based message history), matching the replayIR filter rule.
    @Test
    func bashToolTurnTwoRoundsStillClosesViaStreaming() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            // Round 1: function_call
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
            // Round 2: text reply
            MockResponsesEventStream.textOnlyTurn(
                text: "Ran a minimal Bash command successfully."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        // Use the same session id for both rounds so the bridge stores pendingToolTurns
        // in round 1 and routes round 2 into the continuation branch.
        let sessionID = "session-bash-regression-1"
        let sessionHeader = ["x-claude-code-session-id": sessionID]

        // --- Round 1 ---
        let firstRequest = Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        let firstResponse = await bridge.handleMessages(firstRequest)

        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected .stream body on first response")
            return
        }
        try await firstProducer(firstWriter)

        let firstFrames = await firstWriter.parseSSEFrames()

        // Wire assertion: first turn ends with stop_reason="tool_use".
        var firstSawToolUseStop = false
        for frame in firstFrames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "tool_use" {
                firstSawToolUseStop = true
            }
        }
        #expect(firstSawToolUseStop)

        // Wire assertion: first turn emits a tool_use block.
        var firstSawToolUseBlock = false
        for frame in firstFrames {
            if let cb = frame.data.object("content_block"),
               cb.string("type") == "tool_use",
               cb.string("name") == "Bash" {
                firstSawToolUseBlock = true
            }
        }
        #expect(firstSawToolUseBlock)

        // --- Round 2 (continuation with tool_result) ---
        let secondRequest = Self.makeHTTPRequest(
            body: Self.makeBashHistoryBackedContinuationRequest(toolUseID: "toolu_bash_1"),
            extraHeaders: sessionHeader
        )
        let secondResponse = await bridge.handleMessages(secondRequest)

        let secondWriter = InMemoryBodyWriter()
        guard case .stream(let secondProducer) = secondResponse.body else {
            Issue.record("Expected .stream body on second response")
            return
        }
        try await secondProducer(secondWriter)

        let secondFrames = await secondWriter.parseSSEFrames()

        // Wire assertion: second turn ends with stop_reason="end_turn".
        var secondSawEndTurnStop = false
        for frame in secondFrames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "end_turn" {
                secondSawEndTurnStop = true
            }
        }
        #expect(secondSawEndTurnStop)

        // Wire assertion: second turn emits a text delta.
        var secondSawTextDelta = false
        for frame in secondFrames {
            if frame.data.string("type") == "content_block_delta",
               frame.data.object("delta")?.string("text") != nil {
                secondSawTextDelta = true
            }
        }
        #expect(secondSawTextDelta)

        // --- Critical: continuation payload filter verification ---
        // The second /responses call must only contain reasoning / function_call /
        // function_call_output items (no message history with text content).
        // MockResponsesClient.capturedRequests[1] is the second streamEvents call.
        #expect(await mock.capturedRequests.count >= 2)
        let continuationPayload = await mock.capturedRequests[1]
        let inputItems = continuationPayload.array("input")?.compactMap(\.objectValue) ?? []
        #expect(!inputItems.isEmpty)

        let allowedTypes: Set<String> = ["reasoning", "function_call", "function_call_output"]
        for item in inputItems {
            let itemType = item.string("type") ?? ""
            if !allowedTypes.contains(itemType) {
                Issue.record("Unexpected item type '\(itemType)' in continuation payload; allowed: \(allowedTypes)")
            }
        }
    
        }
    }

    @Test
    func continuationToolContractDriftUsesStoredPendingTools() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
            MockResponsesEventStream.textOnlyTurn(
                text: "Used the original pending tool contract."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-bash-contract-mismatch"]

        let firstResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        )
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected .stream body on first response")
            return
        }
        try await firstProducer(firstWriter)

        let changedTool = Self.makeBashTool(description: "Run a different bash command", includeCWD: true)
        let continuationResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(
                body: Self.makeBashHistoryBackedContinuationRequest(toolUseID: "toolu_bash_1", tools: [changedTool]),
                extraHeaders: sessionHeader
            )
        )

        guard case .stream(let producer) = continuationResponse.body else {
            Issue.record("Expected streaming continuation body")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)
        let frames = await writer.parseSSEFrames()

        var sawEndTurn = false
        for frame in frames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "end_turn" {
                sawEndTurn = true
            }
        }
        #expect(sawEndTurn)

        #expect(await mock.capturedRequests.count == 2)
        #expect(await bridge.pendingToolTurnsCount() == 0)

        let continuationPayload = await mock.capturedRequests[1]
        let continuationTools = continuationPayload.array("tools")?.compactMap(\.objectValue) ?? []
        #expect(continuationTools.count == 1)
        #expect(continuationTools.first?.string("name") == "Bash")
        #expect(continuationTools.first?.string("description") == "Run a bash command")
        #expect(
            continuationTools.first?.object("parameters")?.object("properties")?.object("cwd") == nil
        )
    
        }
    }

    @Test
    func continuationIgnoresHistoricalToolResultsAndSendsOnlyActiveOutputs() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(
                text: "Recovered continuation completed."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: Self.makeRequest(messages: [
            AnthropicMessage(role: "user", content: [
                JSONObject.from(["type": .string("text"), "text": .string("old request")]),
            ]),
            AnthropicMessage(role: "assistant", content: [
                JSONObject.from([
                    "type": .string("tool_use"),
                    "id": .string("toolu_old"),
                    "name": .string("Bash"),
                    "input": .object(JSONObject.from(["command": .string("echo old")])),
                ]),
            ]),
            AnthropicMessage(role: "user", content: [
                JSONObject.from([
                    "type": .string("tool_result"),
                    "tool_use_id": .string("toolu_old"),
                    "content": .string("old success"),
                ]),
            ]),
            AnthropicMessage(role: "assistant", content: [
                JSONObject.from(["type": .string("text"), "text": .string("old round complete")]),
            ]),
            AnthropicMessage(role: "assistant", content: [
                JSONObject.from([
                    "type": .string("thinking"),
                    "thinking": .string("Need the latest tool output"),
                    "signature": .string(Data("sig".utf8).base64EncodedString()),
                ]),
                JSONObject.from([
                    "type": .string("tool_use"),
                    "id": .string("toolu_current"),
                    "name": .string("Bash"),
                    "input": .object(JSONObject.from(["command": .string("echo current")])),
                ]),
            ]),
            AnthropicMessage(role: "user", content: [
                JSONObject.from([
                    "type": .string("tool_result"),
                    "tool_use_id": .string("toolu_current"),
                    "content": .string("current success"),
                ]),
            ]),
        ]))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected history-recovered continuation to stream")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let continuationPayload = await mock.capturedRequests[0]
        let inputItems = continuationPayload.array("input")?.compactMap(\.objectValue) ?? []
        let callIDs = inputItems.compactMap { item -> String? in
            let type = item.string("type") ?? ""
            guard type == "function_call" || type == "function_call_output" else { return nil }
            return item.string("call_id")
        }
        #expect(callIDs == ["toolu_current", "toolu_current"])
        #expect(!callIDs.contains("toolu_old"))
    
        }
    }

    @Test
    func skillContinuationIncludesLoadedSkillBodyText() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(
                text: "Skill body was visible."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let skillBody = "Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"
        let request = Self.makeHTTPRequest(body: Self.makeRequest(
            messages: [
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_skill"),
                        "name": .string("Skill"),
                        "input": .object(JSONObject.from(["skill": .string("domain-intel:scan")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_skill"),
                        "content": .string("Launching skill: domain-intel:scan"),
                    ]),
                    JSONObject.from([
                        "type": .string("text"),
                        "text": .string(skillBody),
                    ]),
                ]),
            ],
            tools: [Self.makeSkillTool()]
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected skill continuation to stream")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let continuationPayload = await mock.capturedRequests[0]
        let inputItems = continuationPayload.array("input")?.compactMap(\.objectValue) ?? []
        #expect(inputItems.map { $0.string("type") ?? "" } == [
            "function_call",
            "function_call_output",
            "message",
        ])
        let toolOutput = try #require(inputItems.dropFirst().first)
        let skillMessage = try #require(inputItems.dropFirst(2).first)
        #expect(toolOutput.string("output") == "Launching skill: domain-intel:scan")
        let skillMessageText = skillMessage
            .array("content")?
            .compactMap(\.objectValue)
            .compactMap { $0.string("text") }
            .joined(separator: "\n")
        #expect(skillMessageText == skillBody)
        #expect(Self.toolNames(in: continuationPayload) == [])

        }
    }

    @Test
    func loadedSlashCommandSkillBodyHidesAdvisorAndSkillOnlyForCurrentTurn() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_pwd",
                argumentsJSON: "{\"command\":\"pwd\"}"
            ),
            MockResponsesEventStream.textOnlyTurn(text: "pwd consumed"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-loaded-skill-initial"]
        let skillBody = "Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"
        let initialRequest = Self.makeHTTPRequest(
            body: Self.makeRequest(
                messages: [
                    AnthropicMessage(role: "user", content: [
                        JSONObject.from([
                            "type": .string("text"),
                            "text": .string("<command-message>domain-intel:scan</command-message>\n<command-name>/domain-intel:scan</command-name>"),
                        ]),
                    ]),
                    AnthropicMessage(role: "user", content: [
                        JSONObject.from(["type": .string("text"), "text": .string(skillBody)]),
                    ]),
                ],
                tools: [Self.makeAdvisorTool(), Self.makeSkillTool(), Self.makeBashTool()]
            ),
            extraHeaders: sessionHeader
        )

        let firstResponse = await bridge.handleMessages(initialRequest)
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected initial loaded skill request to stream")
            return
        }
        try await firstProducer(firstWriter)

        let continuationRequest = Self.makeHTTPRequest(
            body: AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [
                    AnthropicMessage(role: "assistant", content: [
                        JSONObject.from([
                            "type": .string("tool_use"),
                            "id": .string("toolu_pwd"),
                            "name": .string("Bash"),
                            "input": .object(JSONObject.from(["command": .string("pwd")])),
                        ]),
                    ]),
                    AnthropicMessage(role: "user", content: [
                        JSONObject.from([
                            "type": .string("tool_result"),
                            "tool_use_id": .string("toolu_pwd"),
                            "content": .string("/Users/norvyn/Code/InfoHub"),
                        ]),
                    ]),
                ],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ),
            extraHeaders: sessionHeader
        )

        let secondResponse = await bridge.handleMessages(continuationRequest)
        let secondWriter = InMemoryBodyWriter()
        guard case .stream(let secondProducer) = secondResponse.body else {
            Issue.record("Expected Bash continuation to stream")
            return
        }
        try await secondProducer(secondWriter)

        let captured = await mock.capturedRequests
        #expect(captured.count == 2)
        #expect(Self.toolNames(in: captured[0]) == ["Bash"])
        #expect(Self.toolNames(in: captured[1]).contains("Bash"))
        #expect(Self.toolNames(in: captured[1]).contains("Skill"))
        #expect(!Self.toolNames(in: captured[1]).contains("advisor"))

        }
    }

    @Test
    func skillToolResultHandoffHidesSkillAndAdvisorInContinuationPayload() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "handoff consumed"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let skillBody = "Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"
        let request = Self.makeHTTPRequest(body: Self.makeRequest(
            messages: [
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_skill"),
                        "name": .string("Skill"),
                        "input": .object(JSONObject.from(["skill": .string("domain-intel:scan")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_skill"),
                        "content": .string("Launching skill: domain-intel:scan"),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string(skillBody)]),
                ]),
            ],
            tools: [Self.makeAdvisorTool(), Self.makeSkillTool(), Self.makeBashTool()]
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected Skill handoff continuation to stream")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let payload = await mock.capturedRequests[0]
        #expect(Self.toolNames(in: payload) == ["Bash"])

        }
    }

    @Test
    func loadedSkillContextKeepsSkillAvailableAfterNonSkillToolResult() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "Bash result consumed"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let skillBody = "Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"
        let request = Self.makeHTTPRequest(body: Self.makeRequest(
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("text"),
                        "text": .string("<command-message>domain-intel:scan</command-message>\n<command-name>/domain-intel:scan</command-name>"),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string(skillBody)]),
                ]),
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_pwd"),
                        "name": .string("Bash"),
                        "input": .object(JSONObject.from(["command": .string("pwd")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_pwd"),
                        "content": .string("/Users/norvyn/Code/InfoHub"),
                    ]),
                ]),
            ],
            tools: [Self.makeAdvisorTool(), Self.makeSkillTool(), Self.makeBashTool()]
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected loaded skill context continuation to stream")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let payload = await mock.capturedRequests[0]
        #expect(Self.toolNames(in: payload).contains("Bash"))
        #expect(Self.toolNames(in: payload).contains("Skill"))
        #expect(!Self.toolNames(in: payload).contains("advisor"))

        }
    }

    @Test
    func historyRecoveredContinuationSucceedsWithoutPendingCache() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(
                text: "History recovery succeeded."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let response = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeRequest(messages: [
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_recover"),
                        "name": .string("Bash"),
                        "input": .object(JSONObject.from(["command": .string("true")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_recover"),
                        "content": .string("success"),
                    ]),
                ]),
            ]))
        )

        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected recovered continuation to stream")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let frames = await writer.parseSSEFrames()
        #expect(frames.contains {
            $0.data.string("type") == "content_block_delta" &&
            ($0.data.object("delta")?.string("text")?.contains("History") ?? false)
        })
    
        }
    }

    @Test
    func staleToolResultContinuationReturns400BeforeStreamingAndPreservesPending() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-bash-stale-tool-result"]

        let firstResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        )
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected .stream body on first response")
            return
        }
        try await firstProducer(firstWriter)

        let staleResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(
                body: Self.makeBashContinuationRequest(toolUseID: "toolu_bash_stale"),
                extraHeaders: sessionHeader
            )
        )

        #expect(staleResponse.statusCode == 400)
        #expect(await bridge.pendingToolTurnsCount() == 1)
        #expect(await mock.capturedRequests.count == 1)
        if case .stream = staleResponse.body {
            Issue.record("Stale tool_result continuation must not start streaming")
        }

        guard let bodyData = staleResponse.bodyData else {
            Issue.record("Expected buffered JSON error body")
            return
        }
        let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
        #expect(envelope.error.type == "invalid_request_error")
        #expect(envelope.error.message == "orphaned tool_result continuation")
    
        }
    }

    @Test
    func freshSameSessionRequestDuringPendingTurnReturns400AndKeepsPending() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-bash-fresh-during-pending"]

        let firstResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        )
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected .stream body on first response")
            return
        }
        try await firstProducer(firstWriter)

        let freshResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        )

        #expect(freshResponse.statusCode == 400)
        #expect(await bridge.pendingToolTurnsCount() == 1)
        #expect(await mock.capturedRequests.count == 1)
        if case .stream = freshResponse.body {
            Issue.record("Fresh same-session request must not start streaming while a pending turn exists")
        }

        guard let bodyData = freshResponse.bodyData else {
            Issue.record("Expected buffered JSON error body")
            return
        }
        let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
        #expect(envelope.error.type == "invalid_request_error")
        #expect(envelope.error.message == "pending tool turn requires matching tool_result continuation")
    
        }
    }

    @Test
    func stalePendingResolvedInHistoryIsClearedAndFreshTurnProceeds() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
            MockResponsesEventStream.textOnlyTurn(
                text: "Fresh turn succeeds."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-stale-cache-cleared"]
        let firstResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: Self.makeBashRequest(), extraHeaders: sessionHeader)
        )
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected first response stream")
            return
        }
        try await firstProducer(firstWriter)
        #expect(await bridge.pendingToolTurnsCount() == 1)

        let freshRequest = Self.makeHTTPRequest(
            body: Self.makeRequest(messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("old request")]),
                ]),
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_bash_1"),
                        "name": .string("Bash"),
                        "input": .object(JSONObject.from(["command": .string("true")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_bash_1"),
                        "content": .string("success"),
                    ]),
                ]),
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("done")]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("fresh turn")]),
                ]),
            ]),
            extraHeaders: sessionHeader
        )
        let freshResponse = await bridge.handleMessages(freshRequest)
        let freshWriter = InMemoryBodyWriter()
        guard case .stream(let freshProducer) = freshResponse.body else {
            Issue.record("Expected stale cache recovery to stream as a fresh turn")
            return
        }
        try await freshProducer(freshWriter)

        #expect(await mock.capturedRequests.count == 2)
        let payload = await mock.capturedRequests[1]
        let inputItems = payload.array("input")?.compactMap(\.objectValue) ?? []
        #expect(inputItems.contains { $0.string("type") == "message" })
        #expect(await bridge.pendingToolTurnsCount() == 0)
    
        }
    }

    @Test
    func orphanedToolResultReturns400BeforeStreamingAndSkipsUpstream() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let response = await bridge.handleMessages(
            Self.makeHTTPRequest(
                body: Self.makeBashContinuationRequest(toolUseID: "toolu_orphaned"),
                extraHeaders: ["x-claude-code-session-id": "session-orphaned-tool-result"]
            )
        )

        #expect(response.statusCode == 400)
        #expect(await bridge.pendingToolTurnsCount() == 0)
        #expect(await mock.capturedRequests.count == 0)
        if case .stream = response.body {
            Issue.record("Orphaned tool_result must not start streaming")
        }

        guard let bodyData = response.bodyData else {
            Issue.record("Expected buffered JSON error body")
            return
        }
        let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
        #expect(envelope.error.type == "invalid_request_error")
        #expect(envelope.error.message == "orphaned tool_result continuation")
    
        }
    }


    // MARK: - Web search server tool

    @Test
    func anthropicWebSearchToolConvertsToResponsesNativeWebSearch() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: MockResponsesClient(streams: []),
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let converted = try bridge.convertToolsPublic([Self.makeAnthropicWebSearchTool()])
        #expect(converted.count == 1)
        #expect(converted[0].string("type") == "web_search")
        #expect(converted[0].bool("external_web_access") == true)
        #expect(converted[0].array("search_content_types")?.first?.stringValue == "text")
        #expect(converted[0].object("filters")?.array("allowed_domains")?.first?.stringValue == "example.com")

        }
    }

    @Test
    func nativeWebSearchCallStreamsBackAsAnthropicServerToolBlocks() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let callID = "ws_call_1"
        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.webSearchTurn(
                callID: callID,
                query: "ModelBridge competitors",
                sourceURL: "https://example.com/modelbridge",
                sourceTitle: "ModelBridge alternatives",
                finalText: "Found one relevant source."
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let response = await bridge.handleMessages(Self.makeHTTPRequest(body: Self.makeWebSearchRequest()))
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body on web search response")
            return
        }
        try await producer(writer)

        #expect(await mock.capturedRequests.count == 1)
        let payload = await mock.capturedRequests[0]
        let tools = payload.array("tools")?.compactMap(\.objectValue) ?? []
        #expect(tools.count == 1)
        #expect(tools.first?.string("type") == "web_search")
        #expect((payload.array("include") ?? []).contains(.string("web_search_call.action.sources")))

        let frames = await writer.parseSSEFrames()
        var serverToolUseIndex = -1
        var webSearchResultIndex = -1
        var textDeltaIndex = -1
        var sawEndTurn = false

        for (index, frame) in frames.enumerated() {
            if let block = frame.data.object("content_block") {
                if block.string("type") == "server_tool_use",
                   block.string("id") == callID,
                   block.string("name") == "web_search" {
                    serverToolUseIndex = index
                    #expect(block.object("input")?.string("query") == "ModelBridge competitors")
                }
                if block.string("type") == "web_search_tool_result",
                   block.string("tool_use_id") == callID {
                    webSearchResultIndex = index
                    let content = block.array("content")?.compactMap(\.objectValue) ?? []
                    #expect(content.first?.string("type") == "web_search_result")
                    #expect(content.first?.string("url") == "https://example.com/modelbridge")
                }
            }
            if frame.data.string("type") == "content_block_delta",
               frame.data.object("delta")?.string("text") == "Found one relevant source." {
                textDeltaIndex = index
            }
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "end_turn" {
                sawEndTurn = true
            }
        }

        #expect(serverToolUseIndex >= 0)
        #expect(webSearchResultIndex > serverToolUseIndex)
        #expect(textDeltaIndex > webSearchResultIndex)
        #expect(sawEndTurn)

        }
    }


    // MARK: - §3.14: Advisor bridge

    /// Regression: a turn that returns function_call(name="advisor") is bridged by
    /// synthesizing server_tool_use + advisor_tool_result before the final text reply.
    ///
    /// The advisor sub-call is answered by MockResponsesClient.perform which returns
    /// a canned text suggestion.  The bridge must emit, in order:
    ///   1. server_tool_use block (content_block type="server_tool_use", name="advisor")
    ///   2. advisor_tool_result block (content_block type="advisor_tool_result",
    ///      tool_use_id matching the advisor call_id)
    ///   3. Final text delta + message_delta(stop_reason="end_turn")
    

    // MARK: - §3.14: Advisor bridge

    /// Regression: a turn that returns function_call(name="advisor") is bridged by
    /// synthesizing server_tool_use + advisor_tool_result before the final text reply.
    ///
    /// The advisor sub-call is answered by MockResponsesClient.perform which returns
    /// a canned text suggestion.  The bridge must emit, in order:
    ///   1. server_tool_use block (content_block type="server_tool_use", name="advisor")
    ///   2. advisor_tool_result block (content_block type="advisor_tool_result",
    ///      tool_use_id matching the advisor call_id)
    ///   3. Final text delta + message_delta(stop_reason="end_turn")
    @Test
    func advisorBridgeStillSynthesizesServerToolUseAndAdvisorToolResult() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_1"

        let mock = MockResponsesClient(
            streams: [
                // First pass: function_call(name="advisor")
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                // Second pass: final text reply
                MockResponsesEventStream.textOnlyTurn(text: "Final reply"),
            ],
            performResults: [
                // Advisor sub-call result via perform()
                [
                    JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "content": .array([
                                .object(JSONObject.from([
                                    "type": .string("output_text"),
                                    "text": .string("Suggested approach: consider the context"),
                                ])),
                            ]),
                        ])),
                    ]),
                ],
            ]
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: Self.makeAdvisorRequest())
        let response = await bridge.handleMessages(request)

        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body on advisor response")
            return
        }
        try await producer(writer)

        let frames = await writer.parseSSEFrames()

        // Locate frames by content_block subtype.
        var sawServerToolUse = false
        var sawAdvisorToolResult = false
        var sawFinalEndTurn = false
        var serverToolUseIndex = -1
        var advisorToolResultIndex = -1

        for (i, frame) in frames.enumerated() {
            if let cb = frame.data.object("content_block") {
                if cb.string("type") == "server_tool_use",
                   cb.string("name") == "advisor" {
                    sawServerToolUse = true
                    serverToolUseIndex = i
                }
                if cb.string("type") == "advisor_tool_result",
                   cb.string("tool_use_id") == advisorCallID {
                    sawAdvisorToolResult = true
                    advisorToolResultIndex = i
                }
            }
            // message_delta with stop_reason="end_turn" must appear after both blocks.
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "end_turn" {
                if sawServerToolUse && sawAdvisorToolResult {
                    sawFinalEndTurn = true
                }
            }
        }

        if !sawServerToolUse {
            Issue.record("Missing server_tool_use block in advisor bridge wire output")
        }
        if !sawAdvisorToolResult {
            Issue.record("Missing advisor_tool_result block in advisor bridge wire output")
        }
        if !sawFinalEndTurn {
            Issue.record("Missing final message_delta(stop_reason=end_turn) after advisor synthesis")
        }
        if serverToolUseIndex >= advisorToolResultIndex {
            Issue.record("server_tool_use must appear before advisor_tool_result")
        }
    
        }
    }

    @Test
    func advisorSecondPassToolUsePreservesOriginalToolContract() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_2"

        let mock = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "Bash",
                    callID: "toolu_bash_after_advisor",
                    argumentsJSON: "{\"command\":\"pwd\"}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Done after advisor tool"),
            ],
            performResults: [
                [
                    JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "content": .array([
                                .object(JSONObject.from([
                                    "type": .string("output_text"),
                                    "text": .string("Ask Bash for the current directory"),
                                ])),
                            ]),
                        ])),
                    ]),
                ],
            ]
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let sessionHeader = ["x-claude-code-session-id": "session-advisor-preserves-tools"]
        let bashTool = Self.makeBashTool()
        let request = AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("Advise and then run Bash")]),
                ]),
            ],
            system: nil,
            tools: [
                JSONObject.from(["type": .string("advisor_20260301")]),
                bashTool,
            ],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )

        let firstResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: request, extraHeaders: sessionHeader)
        )
        let firstWriter = InMemoryBodyWriter()
        guard case .stream(let firstProducer) = firstResponse.body else {
            Issue.record("Expected .stream body on advisor tool-use response")
            return
        }
        try await firstProducer(firstWriter)

        let continuationRequest = AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "assistant", content: [
                    JSONObject.from([
                        "type": .string("tool_use"),
                        "id": .string("toolu_bash_after_advisor"),
                        "name": .string("Bash"),
                        "input": .object(JSONObject.from(["command": .string("pwd")])),
                    ]),
                ]),
                AnthropicMessage(role: "user", content: [
                    JSONObject.from([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_bash_after_advisor"),
                        "content": .string("pwd output"),
                    ]),
                ]),
            ],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
        let continuationResponse = await bridge.handleMessages(
            Self.makeHTTPRequest(body: continuationRequest, extraHeaders: sessionHeader)
        )
        let continuationWriter = InMemoryBodyWriter()
        guard case .stream(let continuationProducer) = continuationResponse.body else {
            Issue.record("Expected .stream body on continuation response")
            return
        }
        try await continuationProducer(continuationWriter)

        let captured = await mock.capturedRequests
        #expect(captured.count >= 4)
        let secondPassPayload = captured[2]
        let continuationPayload = captured[3]

        let secondPassTools = secondPassPayload.array("tools")?.compactMap(\.objectValue) ?? []
        let continuationTools = continuationPayload.array("tools")?.compactMap(\.objectValue) ?? []

        #expect(secondPassTools.count == 2)
        #expect(continuationTools.count == 2)
        #expect(secondPassTools.contains { $0.string("name") == "Bash" })
        #expect(continuationTools.contains { $0.string("name") == "Bash" })
        #expect(
            continuationTools.first { $0.string("name") == "Bash" }?.string("description") == "Run a bash command"
        )
    
        }
    }

    @Test
    func requestsWithoutSessionHeaderShareStableCacheKey() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "ok"),
            MockResponsesEventStream.textOnlyTurn(text: "ok"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        // No x-claude-code-session-id header — SHA-256 fallback branch must be live.
        let bodyJSON = """
        {"model":"claude-sonnet-4-6","max_tokens":512,"stream":true,
         "messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
        """
        let body = Data(bodyJSON.utf8)
        let req = HTTPRequest(method: "POST", path: "/v1/messages", headers: [:], body: body)

        // Consume both streaming responses so the mock's streamEvents is called.
        for _ in 0..<2 {
            let response = await bridge.handleMessages(req)
            guard case .stream(let producer) = response.body else {
                Issue.record("Expected .stream body")
                return
            }
            let writer = InMemoryBodyWriter()
            try await producer(writer)
        }

        let captured = await mock.capturedRequests
        #expect(captured.count == 2)
        let k1 = captured[0].string("prompt_cache_key")
        let k2 = captured[1].string("prompt_cache_key")
        #expect(k1 == k2)
        #expect(k1?.count == 64)   // SHA-256 hex
    
        }
    }

    @Test
    func rawAnthropicStringContentAndSystemAreNormalizedBeforeBridgeProcessing() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "ok"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let bodyJSON = """
        {"model":"MiniMax-M2.7-highspeed","max_tokens":512,"system":"system prompt",
         "messages":[{"role":"user","content":"dispatch agent"}],"stream":true}
        """
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: [
                "content-type": "application/json",
                "x-claude-code-session-id": "string-content-regression",
            ],
            body: Data(bodyJSON.utf8)
        )

        let response = await bridge.handleMessages(request)
        #expect(response.statusCode == 200)
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let captured = await mock.capturedRequests
        #expect(captured.count == 1)
        #expect(captured[0].string("instructions") == "system prompt")
        let input = captured[0].array("input")?.compactMap(\.objectValue) ?? []
        let firstContent = input.first?.array("content")?.compactMap(\.objectValue).first
        #expect(firstContent?.string("type") == "input_text")
        #expect(firstContent?.string("text") == "dispatch agent")

        }
    }


    // MARK: - Task 5: preflight streamEvents + 401 retry

    /// Verifies that a 401 on the first streamEvents triggers one refresh and one retry.
    /// The second streamEvents (after refresh) succeeds and returns 200.
    

    // MARK: - Task 5: preflight streamEvents + 401 retry

    /// Verifies that a 401 on the first streamEvents triggers one refresh and one retry.
    /// The second streamEvents (after refresh) succeeds and returns 200.
    @Test
    func handleMessagesRetriesOnce401AfterRefresh() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let refreshedCreds = SubscriptionCredentials(
            accessToken: "new-access-token-abc",
            accountID: "test-account",
            refreshToken: "new-refresh",
            lastRefresh: Date()
        )

        // First stream throws 401; second stream returns a valid text turn.
        let mock = MockResponsesClient(
            streams: [
                MockResponsesEventStream.textOnlyTurn(text: "Success after refresh"),
            ]
        )
        await mock.enqueueError(
            ResponsesHTTPError(statusCode: 401, body: "expired")
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(
                credentials: Self.testCredentials,
                refreshedCredentials: refreshedCreds
            )
        )

        let request = Self.makeHTTPRequest(body: Self.makeBashRequest())
        let response = await bridge.handleMessages(request)

        // Must succeed after one retry.
        #expect(response.statusCode == 200)

        // streamEvents called twice: first (401) + second (success after refresh).
        #expect(await mock.capturedRequests.count == 2)

        // refreshAndReload called exactly once.
        let mockLoader = bridge.withSessionLoader(as: MockSessionLoader.self)
        #expect(mockLoader?.refreshAndReloadCallCount == 1)

        // Consume the stream to verify it is valid.
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }
        try await producer(writer)
        let frames = await writer.parseSSEFrames()
        #expect(!frames.isEmpty)
    
        }
    }


    /// Verifies that if the retry (second streamEvents) also returns 401, the bridge
    /// returns 503 with authentication_error type.
    

    /// Verifies that if the retry (second streamEvents) also returns 401, the bridge
    /// returns 503 with authentication_error type.
    @Test
    func secondConsecutive401ReturnsAuthorizationRequired() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let refreshedCreds = SubscriptionCredentials(
            accessToken: "new-access-token-abc",
            accountID: "test-account",
            refreshToken: "new-refresh",
            lastRefresh: Date()
        )

        // Both calls throw 401.
        let mock = MockResponsesClient(streams: [])
        await mock.enqueueError(
            ResponsesHTTPError(statusCode: 401, body: "expired")
        )
        await mock.enqueueError(
            ResponsesHTTPError(statusCode: 401, body: "still expired")
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(
                credentials: Self.testCredentials,
                refreshedCredentials: refreshedCreds
            )
        )

        let request = Self.makeHTTPRequest(body: Self.makeBashRequest())
        let response = await bridge.handleMessages(request)

        #expect(response.statusCode == 503)
        guard let bodyData = response.bodyData else {
            Issue.record("Expected buffered JSON error body")
            return
        }
        let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
        #expect(envelope.error.type == "authentication_error")

        // refreshAndReload called exactly once (no second refresh attempt).
        let mockLoader = bridge.withSessionLoader(as: MockSessionLoader.self)
        #expect(mockLoader?.refreshAndReloadCallCount == 1)
    
        }
    }


    /// Verifies that if refreshAndReload itself throws (e.g. no refresh token),
    /// the bridge returns 503 with authentication_error and a message containing "refresh failed".
    

    /// Verifies that if refreshAndReload itself throws (e.g. no refresh token),
    /// the bridge returns 503 with authentication_error and a message containing "refresh failed".
    @Test
    func refreshFailureDuringRetryReturns503() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [])
        await mock.enqueueError(
            ResponsesHTTPError(statusCode: 401, body: "expired")
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(
                credentials: Self.testCredentials,
                refreshError: SubscriptionSessionError.authorizationRequired(URL(fileURLWithPath: "/"))
            )
        )

        let request = Self.makeHTTPRequest(body: Self.makeBashRequest())
        let response = await bridge.handleMessages(request)

        #expect(response.statusCode == 503)
        guard let bodyData = response.bodyData else {
            Issue.record("Expected buffered JSON error body")
            return
        }
        let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
        #expect(envelope.error.type == "authentication_error")
        #expect(envelope.error.message.contains("refresh failed"))
    
        }
    }
}
