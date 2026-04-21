import Foundation

public actor AnthropicBridge {
    private let configuration: RouterConfiguration
    private let responsesClient: ResponsesClient
    private let sessionLoader: SubscriptionSessionLoader
    private let encoder = JSONEncoder()
    private var pendingToolTurns: [String: PendingToolTurn] = [:]
    private let installationID: String

    public init(
        configuration: RouterConfiguration,
        responsesClient: ResponsesClient? = nil,
        sessionLoader: SubscriptionSessionLoader = SubscriptionSessionLoader()
    ) {
        self.configuration = configuration
        self.responsesClient = responsesClient ?? ResponsesClient(endpoint: URL(string: configuration.responsesURL)!)
        self.sessionLoader = sessionLoader
        self.installationID = UUID().uuidString.lowercased()
    }

    public func handleMessages(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.headers["x-claude-code-session-id"] ?? UUID().uuidString.lowercased()
        let startedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        do {
            let anthropicRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let credentials = try await sessionLoader.loadCurrent()
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("anthropic_in"),
                    "session_id": .string(sessionID),
                    "model": .string(anthropicRequest.model),
                    "message_count": .number(Double(anthropicRequest.messages.count)),
                    "tool_count": .number(Double(anthropicRequest.tools?.count ?? 0)),
                    "has_tool_result": .bool(anthropicRequest.messages.flatMap(\.content).contains { $0.string("type") == "tool_result" }),
                ])
            )

            if let pending = pendingToolTurns[sessionID],
               let continuationPayload = try buildContinuationPayload(from: anthropicRequest, pending: pending) {
                await TraceLogger.shared.log(
                    JSONObject.from([
                        "stage": .string("responses_out_continuation"),
                        "session_id": .string(sessionID),
                        "input_item_types": .array((continuationPayload.array("input") ?? []).map {
                            .string($0.objectValue?.string("type") ?? "<unknown>")
                        }),
                        "function_call_ids": .array((continuationPayload.array("input") ?? []).compactMap { value in
                            guard let object = value.objectValue else { return nil }
                            guard object.string("type") == "function_call" || object.string("type") == "function_call_output" else { return nil }
                            return .string(object.string("call_id") ?? "<missing>")
                        }),
                    ])
                )
                let events = try await responsesClient.perform(request: continuationPayload, credentials: credentials)
                let response = try await finalizeResponse(
                    events: events,
                    anthropicModel: pending.anthropicModel,
                    sessionID: sessionID,
                    convertedTools: pending.convertedTools,
                    advisorEnabled: pending.advisorEnabled,
                    credentials: credentials
                )
                await logRequestOutcome(
                    sessionID: sessionID,
                    response: response,
                    startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                    result: "continuation"
                )
                return response
            }

            let initial = try buildInitialPayload(from: anthropicRequest)
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("responses_out_initial"),
                    "session_id": .string(sessionID),
                    "tool_names": .array(initial.convertedTools.compactMap { tool in
                        tool.string("name").map(JSONValue.string)
                    }),
                    "advisor_enabled": .bool(initial.advisorEnabled),
                ])
            )
            let events = try await responsesClient.perform(request: initial.payload, credentials: credentials)
            let response = try await finalizeResponse(
                events: events,
                anthropicModel: anthropicRequest.model,
                sessionID: sessionID,
                convertedTools: initial.convertedTools,
                advisorEnabled: initial.advisorEnabled,
                credentials: credentials
            )
            await logRequestOutcome(
                sessionID: sessionID,
                response: response,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                result: initial.advisorEnabled ? "advisor_or_tools" : "initial"
            )
            return response
        } catch let error as ResponsesHTTPError {
            let response = anthropicError(statusCode: error.statusCode, errorType: error.statusCode >= 500 ? "api_error" : "invalid_request_error", message: error.body)
            await logRequestOutcome(
                sessionID: sessionID,
                response: response,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                result: "responses_http_error",
                errorType: error.statusCode >= 500 ? "api_error" : "invalid_request_error",
                errorMessage: error.body
            )
            return response
        } catch let error as SubscriptionSessionError {
            let response = anthropicError(statusCode: 503, errorType: "api_error", message: error.localizedDescription)
            await logRequestOutcome(
                sessionID: sessionID,
                response: response,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                result: "subscription_error",
                errorType: "api_error",
                errorMessage: error.localizedDescription
            )
            return response
        } catch {
            let response = anthropicError(statusCode: 400, errorType: "invalid_request_error", message: error.localizedDescription)
            await logRequestOutcome(
                sessionID: sessionID,
                response: response,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                result: "decode_or_bridge_error",
                errorType: "invalid_request_error",
                errorMessage: error.localizedDescription
            )
            return response
        }
    }

    public func doctorStatus() async -> BridgeDoctorStatus {
        do {
            let credentials = try await sessionLoader.loadCurrent()
            return BridgeDoctorStatus(
                chatGPTAuthenticated: true,
                accountIDSuffix: String(credentials.accountID.suffix(6)),
                authError: nil
            )
        } catch {
            return BridgeDoctorStatus(
                chatGPTAuthenticated: false,
                accountIDSuffix: nil,
                authError: error.localizedDescription
            )
        }
    }

    private func finalizeResponse(
        events: [JSONObject],
        anthropicModel: String,
        sessionID: String,
        convertedTools: [JSONObject],
        advisorEnabled: Bool,
        credentials: SubscriptionCredentials
    ) async throws -> HTTPResponse {
        let outputItems = outputItemsInOrder(from: events)
        let functionCalls = outputItems.filter { $0.string("type") == "function_call" }
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("responses_in"),
                "session_id": .string(sessionID),
                "output_item_types": .array(outputItems.compactMap { $0.string("type").map(JSONValue.string) }),
                "function_calls": .array(functionCalls.map { call in
                    .object(
                        JSONObject.from([
                            "name": .string(call.string("name") ?? "<missing>"),
                            "call_id": .string(call.string("call_id") ?? "<missing>"),
                        ])
                    )
                }),
            ])
        )

        if advisorEnabled, let advisorCall = functionCalls.first(where: { $0.string("name") == "advisor" }) {
            let advisorText = try await runAdvisorSubcall(credentials: credentials)
            let replayItems = replayItemsForContinuation(from: outputItems)
            let finalPayload = makeResponsesPayload(
                model: configuration.executorModel,
                instructions: "",
                input: replayItems + [
                    .object(
                        JSONObject.from([
                            "type": .string("function_call_output"),
                            "call_id": .string(advisorCall.string("call_id") ?? ""),
                            "output": .string(advisorText),
                        ])
                    )
                ],
                tools: convertedTools,
                toolChoice: .string("auto")
            )
            let finalEvents = try await responsesClient.perform(request: finalPayload, credentials: credentials)
            let finalOutputItems = outputItemsInOrder(from: finalEvents)
            let advisorContinuationCalls = finalOutputItems.filter { $0.string("type") == "function_call" }
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("responses_in_advisor_continuation"),
                    "session_id": .string(sessionID),
                    "output_item_types": .array(finalOutputItems.compactMap { $0.string("type").map(JSONValue.string) }),
                    "function_calls": .array(advisorContinuationCalls.map { call in
                        .object(
                            JSONObject.from([
                                "name": .string(call.string("name") ?? "<missing>"),
                                "call_id": .string(call.string("call_id") ?? "<missing>"),
                            ])
                        )
                    }),
                ])
            )
            let stopReason = advisorContinuationCalls.isEmpty ? "end_turn" : "tool_use"
            let body = try makeAdvisorSSE(
                anthropicModel: anthropicModel,
                firstPassItems: outputItems,
                advisorCall: advisorCall,
                advisorText: advisorText,
                finalEvents: finalEvents,
                stopReason: stopReason
            )
            if advisorContinuationCalls.isEmpty {
                pendingToolTurns.removeValue(forKey: sessionID)
            } else {
                pendingToolTurns[sessionID] = PendingToolTurn(
                    anthropicModel: anthropicModel,
                    convertedTools: convertedTools,
                    replayItems: replayItemsForContinuation(from: finalOutputItems),
                    advisorEnabled: advisorEnabled
                )
            }
            return HTTPResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                ],
                body: body
            )
        }

        if !functionCalls.isEmpty {
            pendingToolTurns[sessionID] = PendingToolTurn(
                anthropicModel: anthropicModel,
                convertedTools: convertedTools,
                replayItems: replayItemsForContinuation(from: outputItems),
                advisorEnabled: advisorEnabled
            )
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("pending_tool_turn_store"),
                    "session_id": .string(sessionID),
                    "replay_item_types": .array(replayItemsForContinuation(from: outputItems).map {
                        .string($0.objectValue?.string("type") ?? "<unknown>")
                    }),
                ])
            )
            let body = try makeToolUseSSE(anthropicModel: anthropicModel, events: events)
            return HTTPResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                ],
                body: body
            )
        }

        pendingToolTurns.removeValue(forKey: sessionID)
        let body = try makeTextSSE(anthropicModel: anthropicModel, events: events)
        return HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            ],
            body: body
        )
    }

    private func buildInitialPayload(from request: AnthropicMessagesRequest) throws -> InitialPayload {
        let tools = try convertTools(request.tools ?? [])
        let input = convertMessages(request.messages)
        let instructions = joinedSystemText(from: request.system ?? [])
        return InitialPayload(
            payload: makeResponsesPayload(
                model: configuration.executorModel,
                instructions: instructions,
                input: input,
                tools: tools.convertedTools,
                toolChoice: .string("auto")
            ),
            convertedTools: tools.convertedTools,
            advisorEnabled: tools.advisorEnabled
        )
    }

    private func buildContinuationPayload(from request: AnthropicMessagesRequest, pending: PendingToolTurn) throws -> JSONObject? {
        let outputs = try functionCallOutputs(
            from: request,
            allowedCallIDs: Set(pending.replayItems.compactMap { item in
                guard let object = item.objectValue else { return nil }
                guard object.string("type") == "function_call" else { return nil }
                return object.string("call_id")
            })
        )
        guard !outputs.isEmpty else { return nil }
        return makeResponsesPayload(
            model: configuration.executorModel,
            instructions: "",
            input: pending.replayItems + outputs,
            tools: pending.convertedTools,
            toolChoice: .string("auto")
        )
    }

    private func convertMessages(_ messages: [AnthropicMessage]) -> [JSONValue] {
        messages.compactMap { message in
            let content = convertContentBlocks(message.content)
            guard !content.isEmpty else { return nil }
            return .object(
                JSONObject.from([
                    "type": .string("message"),
                    "role": .string(message.role),
                    "content": .array(content.map(\.asJSONValue)),
                ])
            )
        }
    }

    private func convertContentBlocks(_ blocks: [JSONObject]) -> [ResponsesContentPart] {
        blocks.compactMap { block in
            switch block.string("type") {
            case "text":
                guard let text = block.string("text"), !text.isEmpty else { return nil }
                return ResponsesContentPart(type: "input_text", text: text)
            default:
                return nil
            }
        }
    }

    private func joinedSystemText(from blocks: [JSONObject]) -> String {
        blocks.compactMap { block in
            guard block.string("type") == "text" else { return nil }
            return block.string("text")
        }
        .joined(separator: "\n\n")
    }

    private func convertTools(_ tools: [JSONObject]) throws -> ConvertedTools {
        var converted: [JSONObject] = []
        var advisorEnabled = false

        for tool in tools {
            switch tool.string("type") ?? "function" {
            case "function":
                guard
                    let name = tool.string("name"),
                    let description = tool.string("description"),
                    let schema = tool.object("input_schema")
                else {
                    continue
                }
                converted.append(
                    JSONObject.from([
                        "type": .string("function"),
                        "name": .string(name),
                        "description": .string(description),
                        "strict": .bool(false),
                        "parameters": .object(schema),
                    ])
                )
            case "advisor_20260301":
                advisorEnabled = true
                converted.append(
                    JSONObject.from([
                        "type": .string("function"),
                        "name": .string("advisor"),
                        "description": .string("Ask a stronger planning advisor for concise strategic guidance."),
                        "strict": .bool(false),
                        "parameters": .object(
                            JSONObject.from([
                                "type": .string("object"),
                                "properties": .object(JSONObject()),
                                "additionalProperties": .bool(false),
                            ])
                        ),
                    ])
                )
            default:
                continue
            }
        }

        return ConvertedTools(convertedTools: converted, advisorEnabled: advisorEnabled)
    }

    private func replayItemsForContinuation(from outputItems: [JSONObject]) -> [JSONValue] {
        outputItems
            .filter {
                let type = $0.string("type")
                return type == "reasoning" || type == "function_call"
            }
            .map(JSONValue.object)
    }

    private func outputItemsInOrder(from events: [JSONObject]) -> [JSONObject] {
        events.compactMap { event in
            guard event.string("type") == "response.output_item.done" else { return nil }
            return event.object("item")
        }
    }

    private func finalUsage(from events: [JSONObject]) -> (input: Int, output: Int)? {
        guard
            let completed = events.last(where: { $0.string("type") == "response.completed" }),
            let response = completed.object("response"),
            let usage = response.object("usage")
        else {
            return nil
        }
        return (usage["input_tokens"]?.intValue ?? 0, usage["output_tokens"]?.intValue ?? 0)
    }

    private func makeTextSSE(anthropicModel: String, events: [JSONObject]) throws -> Data {
        let outputItems = outputItemsInOrder(from: events)
        let usage = finalUsage(from: events) ?? (0, 0)
        return try buildAnthropicSSE(
            anthropicModel: anthropicModel,
            outputItems: outputItems,
            usage: usage,
            stopReason: "end_turn"
        )
    }

    private func makeToolUseSSE(anthropicModel: String, events: [JSONObject]) throws -> Data {
        let outputItems = outputItemsInOrder(from: events)
        let usage = finalUsage(from: events) ?? (0, 0)
        return try buildAnthropicSSE(
            anthropicModel: anthropicModel,
            outputItems: outputItems,
            usage: usage,
            stopReason: "tool_use"
        )
    }

    private func makeAdvisorSSE(
        anthropicModel: String,
        firstPassItems: [JSONObject],
        advisorCall: JSONObject,
        advisorText: String,
        finalEvents: [JSONObject],
        stopReason: String
    ) throws -> Data {
        var synthesizedItems = firstPassItems.filter { $0.string("type") == "message" }
        synthesizedItems.append(
            JSONObject.from([
                "type": .string("server_tool_use"),
                "id": .string(advisorCall.string("call_id") ?? UUID().uuidString.lowercased()),
                "name": .string("advisor"),
                "input": .object(JSONObject()),
            ])
        )
        synthesizedItems.append(
            JSONObject.from([
                "type": .string("advisor_tool_result"),
                "tool_use_id": .string(advisorCall.string("call_id") ?? UUID().uuidString.lowercased()),
                "content": .object(
                    JSONObject.from([
                        "type": .string("advisor_result"),
                        "text": .string(advisorText),
                    ])
                ),
            ])
        )
        synthesizedItems.append(contentsOf: outputItemsInOrder(from: finalEvents).filter { $0.string("type") == "message" })
        synthesizedItems.append(contentsOf: outputItemsInOrder(from: finalEvents).filter { $0.string("type") == "function_call" })

        let usage = finalUsage(from: finalEvents) ?? (0, 0)
        return try buildAnthropicSSE(
            anthropicModel: anthropicModel,
            outputItems: synthesizedItems,
            usage: usage,
            stopReason: stopReason
        )
    }

    private func buildAnthropicSSE(
        anthropicModel: String,
        outputItems: [JSONObject],
        usage: (input: Int, output: Int),
        stopReason: String
    ) throws -> Data {
        var chunks: [Data] = [
            try sse(event: "message_start", data: JSONObject.from([
                "type": .string("message_start"),
                "message": .object(
                    JSONObject.from([
                        "id": .string("msg_\(UUID().uuidString.lowercased())"),
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "model": .string(anthropicModel),
                        "content": .array([]),
                        "stop_reason": .null,
                        "stop_sequence": .null,
                        "usage": .object(
                            JSONObject.from([
                                "input_tokens": .number(Double(max(1, usage.input))),
                                "output_tokens": .number(1),
                            ])
                        ),
                    ])
                ),
            ])),
        ]

        var blockIndex = 0

        for item in outputItems {
            switch item.string("type") {
            case "message":
                let parts = item.array("content")?.compactMap(\.objectValue) ?? []
                for part in parts where (part.string("type") == "output_text" || part.string("type") == "text") {
                    let text = part.string("text") ?? ""
                    chunks.append(
                        try sse(event: "content_block_start", data: JSONObject.from([
                            "type": .string("content_block_start"),
                            "index": .number(Double(blockIndex)),
                            "content_block": .object(
                                JSONObject.from([
                                    "type": .string("text"),
                                    "text": .string(""),
                                ])
                            ),
                        ]))
                    )
                    if !text.isEmpty {
                        chunks.append(
                            try sse(event: "content_block_delta", data: JSONObject.from([
                                "type": .string("content_block_delta"),
                                "index": .number(Double(blockIndex)),
                                "delta": .object(
                                    JSONObject.from([
                                        "type": .string("text_delta"),
                                        "text": .string(text),
                                    ])
                                ),
                            ]))
                        )
                    }
                    chunks.append(
                        try sse(event: "content_block_stop", data: JSONObject.from([
                            "type": .string("content_block_stop"),
                            "index": .number(Double(blockIndex)),
                        ]))
                    )
                    blockIndex += 1
                }
            case "function_call":
                let arguments = item.string("arguments") ?? "{}"
                chunks.append(
                    try sse(event: "content_block_start", data: JSONObject.from([
                        "type": .string("content_block_start"),
                        "index": .number(Double(blockIndex)),
                        "content_block": .object(
                            JSONObject.from([
                                "type": .string("tool_use"),
                                "id": .string(item.string("call_id") ?? UUID().uuidString.lowercased()),
                                "name": .string(item.string("name") ?? "tool"),
                                "input": .object(JSONObject()),
                            ])
                        ),
                    ]))
                )
                chunks.append(
                    try sse(event: "content_block_delta", data: JSONObject.from([
                        "type": .string("content_block_delta"),
                        "index": .number(Double(blockIndex)),
                        "delta": .object(
                            JSONObject.from([
                                "type": .string("input_json_delta"),
                                "partial_json": .string(arguments),
                            ])
                        ),
                    ]))
                )
                chunks.append(
                    try sse(event: "content_block_stop", data: JSONObject.from([
                        "type": .string("content_block_stop"),
                        "index": .number(Double(blockIndex)),
                    ]))
                )
                blockIndex += 1
            case "server_tool_use":
                chunks.append(
                    try sse(event: "content_block_start", data: JSONObject.from([
                        "type": .string("content_block_start"),
                        "index": .number(Double(blockIndex)),
                        "content_block": .object(item),
                    ]))
                )
                chunks.append(
                    try sse(event: "content_block_stop", data: JSONObject.from([
                        "type": .string("content_block_stop"),
                        "index": .number(Double(blockIndex)),
                    ]))
                )
                blockIndex += 1
            case "advisor_tool_result":
                chunks.append(
                    try sse(event: "content_block_start", data: JSONObject.from([
                        "type": .string("content_block_start"),
                        "index": .number(Double(blockIndex)),
                        "content_block": .object(item),
                    ]))
                )
                chunks.append(
                    try sse(event: "content_block_stop", data: JSONObject.from([
                        "type": .string("content_block_stop"),
                        "index": .number(Double(blockIndex)),
                    ]))
                )
                blockIndex += 1
            default:
                continue
            }
        }

        chunks.append(
            try sse(event: "message_delta", data: JSONObject.from([
                "type": .string("message_delta"),
                "delta": .object(
                    JSONObject.from([
                        "stop_reason": .string(stopReason),
                        "stop_sequence": .null,
                    ])
                ),
                "usage": .object(
                    JSONObject.from([
                        "output_tokens": .number(Double(max(1, usage.output))),
                    ])
                ),
            ]))
        )
        chunks.append(try sse(event: "message_stop", data: JSONObject.from(["type": .string("message_stop")])))

        return chunks.reduce(into: Data(), { $0.append($1) })
    }

    private func functionCallOutputs(from request: AnthropicMessagesRequest, allowedCallIDs: Set<String>) throws -> [JSONValue] {
        let toolResults = request.messages
            .flatMap(\.content)
            .filter { block in
                guard block.string("type") == "tool_result" else { return false }
                guard let toolUseID = block.string("tool_use_id") else { return false }
                return allowedCallIDs.contains(toolUseID)
            }

        var seenCallIDs = Set<String>()
        return try toolResults.compactMap { block in
            guard let toolUseID = block.string("tool_use_id") else {
                throw ResponsesHTTPError(statusCode: 400, body: "tool_result missing tool_use_id")
            }
            guard seenCallIDs.insert(toolUseID).inserted else { return nil }
            return .object(
                JSONObject.from([
                    "type": .string("function_call_output"),
                    "call_id": .string(toolUseID),
                    "output": .string(stringifyToolResultContent(block["content"])),
                ])
            )
        }
    }

    private func stringifyToolResultContent(_ value: JSONValue?) -> String {
        switch value {
        case .string(let string):
            return string
        case .array(let items):
            let text = items.compactMap { item -> String? in
                guard let object = item.objectValue else { return nil }
                guard object.string("type") == "text" else { return nil }
                return object.string("text")
            }.joined(separator: "\n")
            return text.isEmpty ? encodeJSON(value) : text
        case .object(let object):
            if object.string("type") == "text", let text = object.string("text") {
                return text
            }
            return encodeJSON(.object(object))
        case .number(let number):
            return String(number)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, nil:
            return ""
        }
    }

    private func runAdvisorSubcall(credentials: SubscriptionCredentials) async throws -> String {
        let advisorPayload = makeResponsesPayload(
            model: configuration.advisorModel,
            instructions: "You are a planning advisor. Return only a short guidance paragraph with the best next-step strategy.",
            input: [
                .object(
                    JSONObject.from([
                        "type": .string("message"),
                        "role": .string("user"),
                        "content": .array([
                            ResponsesContentPart(type: "input_text", text: "Provide concise strategic guidance for the current task.").asJSONValue,
                        ]),
                    ])
                ),
            ],
            tools: [],
            toolChoice: .string("none")
        )
        let events = try await responsesClient.perform(request: advisorPayload, credentials: credentials)
        return joinedMessageText(from: outputItemsInOrder(from: events))
    }

    private func joinedMessageText(from outputItems: [JSONObject]) -> String {
        outputItems
            .filter { $0.string("type") == "message" }
            .flatMap { item in
                item.array("content")?.compactMap { value -> String? in
                    guard let object = value.objectValue else { return nil }
                    guard object.string("type") == "output_text" || object.string("type") == "text" else { return nil }
                    return object.string("text")
                } ?? []
            }
            .joined(separator: "")
    }

    private func encodeJSON(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        let data = try? encoder.encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func makeResponsesPayload(
        model: String,
        instructions: String,
        input: [JSONValue],
        tools: [JSONObject],
        toolChoice: JSONValue
    ) -> JSONObject {
        JSONObject.from([
            "model": .string(model),
            "instructions": .string(instructions),
            "input": .array(input),
            "tools": .array(tools.map(JSONValue.object)),
            "tool_choice": toolChoice,
            "parallel_tool_calls": .bool(true),
            "reasoning": .object(JSONObject.from(["effort": .string("xhigh")])),
            "store": .bool(false),
            "stream": .bool(true),
            "include": .array([.string("reasoning.encrypted_content")]),
            "service_tier": .string("priority"),
            "prompt_cache_key": .string(UUID().uuidString.lowercased()),
            "text": .object(JSONObject.from(["verbosity": .string("low")])),
            "client_metadata": .object(
                JSONObject.from([
                    "x-codex-installation-id": .string(installationID),
                ])
            ),
        ])
    }

    private func logRequestOutcome(
        sessionID: String,
        response: HTTPResponse,
        startedAtUptimeNanoseconds: UInt64,
        result: String,
        errorType: String? = nil,
        errorMessage: String? = nil
    ) async {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAtUptimeNanoseconds
        let durationMilliseconds = Int(elapsedNanoseconds / 1_000_000)
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("anthropic_out"),
                "session_id": .string(sessionID),
                "status_code": .number(Double(response.statusCode)),
                "result": .string(result),
                "duration_ms": .number(Double(durationMilliseconds)),
                "error_type": errorType.map(JSONValue.string) ?? .null,
                "error_message": errorMessage.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private func anthropicError(statusCode: Int, errorType: String, message: String) -> HTTPResponse {
        let envelope = AnthropicErrorEnvelope(error: AnthropicErrorBody(type: errorType, message: message))
        return try! HTTPResponse.json(
            statusCode: statusCode,
            reasonPhrase: statusCode >= 500 ? "Internal Server Error" : "Bad Request",
            value: envelope
        )
    }

    private func sse(event: String, data: JSONObject) throws -> Data {
        let json = try encoder.encode(data)
        var payload = Data("event: \(event)\n".utf8)
        payload.append(Data("data: ".utf8))
        payload.append(json)
        payload.append(Data("\n\n".utf8))
        return payload
    }
}

public struct BridgeDoctorStatus: Sendable {
    public let chatGPTAuthenticated: Bool
    public let accountIDSuffix: String?
    public let authError: String?
}

private struct ResponsesContentPart: Sendable {
    let type: String
    let text: String

    var asJSONValue: JSONValue {
        .object(
            JSONObject.from([
                "type": .string(type),
                "text": .string(text),
            ])
        )
    }
}

private struct ConvertedTools: Sendable {
    let convertedTools: [JSONObject]
    let advisorEnabled: Bool
}

private struct InitialPayload: Sendable {
    let payload: JSONObject
    let convertedTools: [JSONObject]
    let advisorEnabled: Bool
}

private struct PendingToolTurn: Sendable {
    let anthropicModel: String
    let convertedTools: [JSONObject]
    let replayItems: [JSONValue]
    let advisorEnabled: Bool
}
