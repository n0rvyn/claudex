import Foundation
@testable import CCRouterCore
import Testing

struct CountTokensEndpointTests {
    // MARK: - Shared configuration

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

    private static func makeCountTokensRequest(body: AnthropicMessagesRequest) -> HTTPRequest {
        let bodyData = try! JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages/count_tokens",
            headers: [
                "content-type": "application/json",
                LocalGatewayAuthorization.expectedHeader: "test-token",
            ],
            body: bodyData
        )
    }

    /// Builds an AnthropicMessagesRequest for testing.
    private static func makeRequest(
        model: String = "claude-sonnet-4-6",
        messages: [AnthropicMessage],
        system: [JSONObject]? = nil,
        tools: [JSONObject]? = nil
    ) -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: model,
            max_tokens: 4096,
            messages: messages,
            system: system,
            tools: tools,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: false
        )
    }

    // MARK: - Tests

    /// A simple text message returns a positive token count.
    @Test
    func singleTextMessageReturnsPositiveCount() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let request = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("hello world")]),
                        ])
                    ]
                )
            )

            let response = await bridge.handleCountTokens(request)

            #expect(response.statusCode == 200)
            guard let bodyData = response.bodyData else {
                Issue.record("Expected buffered JSON body")
                return
            }
            let result = try JSONDecoder().decode(CountTokensResult.self, from: bodyData)
            #expect(result.input_tokens > 0)
        }
    }

    /// A larger payload yields a larger count than a smaller one.
    @Test
    func largerPayloadReturnsLargerCount() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let shortText = String(repeating: "x", count: 200)
            let longText = String(repeating: "x", count: 1000)

            let shortRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string(shortText)])
                        ])
                    ]
                )
            )

            let longRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string(longText)])
                        ])
                    ]
                )
            )

            let shortResponse = await bridge.handleCountTokens(shortRequest)
            let longResponse = await bridge.handleCountTokens(longRequest)

            let shortBody = try JSONDecoder().decode(CountTokensResult.self, from: shortResponse.bodyData!)
            let longBody = try JSONDecoder().decode(CountTokensResult.self, from: longResponse.bodyData!)

            #expect(longBody.input_tokens > shortBody.input_tokens)
        }
    }

    @Test
    func invalidJSONReturns400() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let badRequest = HTTPRequest(
                method: "POST",
                path: "/v1/messages/count_tokens",
                headers: [
                    "content-type": "application/json",
                    LocalGatewayAuthorization.expectedHeader: "test-token",
                ],
                body: Data("not json at all".utf8)
            )

            let response = await bridge.handleCountTokens(badRequest)

            #expect(response.statusCode == 400)
            guard let bodyData = response.bodyData else {
                Issue.record("Expected buffered JSON error body")
                return
            }
            let envelope = try JSONDecoder().decode(AnthropicErrorEnvelope.self, from: bodyData)
            #expect(envelope.error.type == "invalid_request_error")
        }
    }

    @Test
    func toolSchemaIncreasesCount() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            // Use a large parameter schema: after convertTools strips description/name,
            // the remaining canonical JSON of the params (with sorted keys) must still add
            // enough tokens to reliably exceed the "Run it" baseline of 2 tokens.
            let largeParams = JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "pattern": .object(JSONObject.from(["type": .string("string"), "description": .string("The regular expression pattern to search for")])),
                    "path": .object(JSONObject.from(["type": .string("string"), "description": .string("The directory or file path to search within")])),
                    "recursive": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether to search recursively through subdirectories")])),
                    "ignoreCase": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether the search should be case-insensitive")])),
                    "include": .object(JSONObject.from(["type": .string("string"), "description": .string("File patterns to include (e.g., *.swift, *.json)")])),
                    "exclude": .object(JSONObject.from(["type": .string("string"), "description": .string("File patterns to exclude from the search")])),
                    "count": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Only print the count of matching lines")])),
                    "invertMatch": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Invert the match to show non-matching lines")])),
                    "lineNumber": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Print line numbers with each match")])),
                    "maxCount": .object(JSONObject.from(["type": .string("integer"), "description": .string("Stop searching after N matches per file")])),
                    "after": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines after each match")])),
                    "before": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines before each match")])),
                    "context": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines of context around each match")])),
                    "maxDepth": .object(JSONObject.from(["type": .string("integer"), "description": .string("Maximum directory depth for recursive search")])),
                    "followSymlinks": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether to follow symbolic links")])),
                    "noMessages": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Suppress error messages")])),
                ])),
                "required": .array([.string("pattern"), .string("path")]),
            ])
            let toolDef = JSONObject.from([
                "type": .string("function"),
                "name": .string("Bash"),
                "description": .string("Run a bash command"),
                "parameters": .object(largeParams),
            ])

            let baseRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("Run it")])
                        ]),
                    ]
                )
            )

            let withToolsRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("Run it")])
                        ]),
                    ],
                    tools: [toolDef]
                )
            )

            let baseResponse = await bridge.handleCountTokens(baseRequest)
            let withToolsResponse = await bridge.handleCountTokens(withToolsRequest)

            let baseCount = try JSONDecoder().decode(CountTokensResult.self, from: baseResponse.bodyData!).input_tokens
            let withToolsCount = try JSONDecoder().decode(CountTokensResult.self, from: withToolsResponse.bodyData!).input_tokens

            #expect(withToolsCount > baseCount)
        }
    }

    @Test
    func endpointCountMatchesInputTokenCounterDirectly() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let counter = AnthropicInputTokenCounter()

            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let request = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("hello world")])
                        ]),
                    ],
                    system: [
                        JSONObject.from(["type": .string("text"), "text": .string("You are a helpful assistant.")])
                    ],
                    tools: [
                        JSONObject.from([
                            "type": .string("function"),
                            "name": .string("Bash"),
                            "description": .string("Run a bash command"),
                            "parameters": .object(JSONObject.from([
                                "type": .string("object"),
                                "properties": .object(JSONObject.from([
                                    "pattern": .object(JSONObject.from(["type": .string("string"), "description": .string("The regular expression pattern to search for")])),
                                    "path": .object(JSONObject.from(["type": .string("string"), "description": .string("The directory or file path to search within")])),
                                    "recursive": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether to search recursively through subdirectories")])),
                                    "ignoreCase": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether the search should be case-insensitive")])),
                                    "include": .object(JSONObject.from(["type": .string("string"), "description": .string("File patterns to include")])),
                                    "exclude": .object(JSONObject.from(["type": .string("string"), "description": .string("File patterns to exclude")])),
                                    "count": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Only print the count of matching lines")])),
                                    "invertMatch": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Invert the match to show non-matching lines")])),
                                    "lineNumber": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Print line numbers with each match")])),
                                    "maxCount": .object(JSONObject.from(["type": .string("integer"), "description": .string("Stop searching after N matches per file")])),
                                    "after": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines after each match")])),
                                    "before": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines before each match")])),
                                    "context": .object(JSONObject.from(["type": .string("integer"), "description": .string("Print N lines of context around each match")])),
                                    "maxDepth": .object(JSONObject.from(["type": .string("integer"), "description": .string("Maximum directory depth for recursive search")])),
                                    "followSymlinks": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Whether to follow symbolic links")])),
                                    "noMessages": .object(JSONObject.from(["type": .string("boolean"), "description": .string("Suppress error messages")])),
                                ])),
                                "required": .array([.string("pattern"), .string("path")]),
                            ])),
                        ])
                    ]
                )
            )

            let endpointResponse = await bridge.handleCountTokens(request)
            let endpointResult = try JSONDecoder().decode(CountTokensResult.self, from: endpointResponse.bodyData!)

            // Build the same countable payload directly and count.
            let anthropicRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let countablePayload = buildCountablePayload(from: anthropicRequest, bridge: bridge)
            let directCount = try await counter.countInputTokens(for: countablePayload)

            #expect(endpointResult.input_tokens == directCount)
        }
    }

    @Test
    func toolCallHistoryIsCounted() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            // Baseline: just a user text message.
            let baselineRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("hello")])
                        ])
                    ]
                )
            )
            let baselineResponse = await bridge.handleCountTokens(baselineRequest)
            let baselineCount = try JSONDecoder().decode(CountTokensResult.self, from: baselineResponse.bodyData!).input_tokens

            // With tool call history: assistant tool_use + user tool_result.
            let historyRequest = Self.makeCountTokensRequest(
                body: Self.makeRequest(
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from(["type": .string("text"), "text": .string("hello")])
                        ]),
                        AnthropicMessage(role: "assistant", content: [
                            JSONObject.from([
                                "type": .string("tool_use"),
                                "id": .string("toolu_1"),
                                "name": .string("Bash"),
                                "input": .object(JSONObject.from(["command": .string("echo hello")]))
                            ])
                        ]),
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from([
                                "type": .string("tool_result"),
                                "tool_use_id": .string("toolu_1"),
                                "content": .string("hello"),
                            ])
                        ]),
                    ]
                )
            )
            let historyResponse = await bridge.handleCountTokens(historyRequest)
            let historyCount = try JSONDecoder().decode(CountTokensResult.self, from: historyResponse.bodyData!).input_tokens

            #expect(historyCount > baselineCount)
        }
    }

    @Test
    func endpointMatchesBridgePrepareTurnInitialPayload() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let requestBody = Self.makeRequest(
                model: "claude-sonnet-4-6",
                messages: [
                    AnthropicMessage(role: "user", content: [
                        JSONObject.from(["type": .string("text"), "text": .string("Write a hello world program in Python")])
                    ]),
                ],
                system: [
                    JSONObject.from(["type": .string("text"), "text": .string("You are a helpful coding assistant.")])
                ],
                tools: [
                    JSONObject.from([
                        "type": .string("function"),
                        "name": .string("Bash"),
                        "description": .string("Run a bash command"),
                        "parameters": .object(JSONObject.from([
                            "type": .string("object"),
                            "properties": .object(JSONObject.from([
                                "command": .object(JSONObject.from(["type": .string("string")])),
                            ])),
                        ])),
                    ])
                ]
            )

            // Route through the bridge's handleCountTokens path.
            let httpRequest = Self.makeCountTokensRequest(body: requestBody)
            let countTokensResponse = await bridge.handleCountTokens(httpRequest)
            #expect(countTokensResponse.statusCode == 200)
            let endpointCount = try JSONDecoder().decode(CountTokensResult.self, from: countTokensResponse.bodyData!).input_tokens

            // Get the same count via prepareTurn's messageStartInputTokens.
            let sessionID = "count-tokens-parity-test"
            let sessionHeader = "x-claude-code-session-id"
            let preparedTurn = try await bridge.prepareTurnForTesting(
                request: requestBody,
                sessionID: sessionID,
                sessionHeader: sessionHeader
            )
            let bridgeCount = preparedTurn.messageStartInputTokens

            #expect(endpointCount == bridgeCount)
        }
    }
}

// MARK: - Test helpers

/// Mirrors buildCountablePayload from AnthropicBridge using its public helpers.
/// Passes tools as-is (raw Anthropic tool defs) to match handleCountTokens' direct path.
private func buildCountablePayload(from request: AnthropicMessagesRequest, bridge: AnthropicBridge) -> JSONObject {
    let requestIR: [IRMessage] = request.messages.map { msg in
        IRMessage(
            role: msg.role,
            content: IRAnthropicCodec.decodeRequestBlocks(msg.content)
        )
    }
    let systemText = request.system?.compactMap { block -> String? in
        guard block.string("type") == "text" else { return nil }
        return block.string("text")
    }.joined(separator: "\n\n") ?? ""
    return JSONObject.from([
        "instructions": .string(systemText),
        "input": .array(IRResponsesCodec.encodeFullHistory(requestIR)),
        "tools": .array((request.tools ?? []).map(JSONValue.object)),
    ])
}
