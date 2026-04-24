import Foundation

// MARK: - ResponsesStreamingClient protocol

/// Protocol allowing `AnthropicBridge` to be tested with a mock streaming client.
public protocol ResponsesStreamingClient: Sendable {
    func streamEvents(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> AsyncThrowingStream<JSONObject, Error>

    func perform(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> [JSONObject]
}

extension ResponsesClient: ResponsesStreamingClient {}

// MARK: - AnthropicBridge

public actor AnthropicBridge {
    private let configuration: RouterConfiguration
    private var routingTable: ModelRoutingTable
    private var advisorRoute: ModelRoute
    private let responsesClient: any ResponsesStreamingClient
    private let sessionLoader: any SubscriptionSessionProviding
    private let inputTokenCounter: any AnthropicInputTokenCounting
    private let encoder = JSONEncoder()
    private var pendingToolTurns: [String: PendingToolTurn] = [:]
    private let installationID: String

    public init(
        configuration: RouterConfiguration,
        responsesClient: (any ResponsesStreamingClient)? = nil,
        sessionLoader: (any SubscriptionSessionProviding)? = nil,
        inputTokenCounter: (any AnthropicInputTokenCounting)? = nil
    ) {
        self.configuration = configuration
        self.routingTable = configuration.routingTable
        self.advisorRoute = configuration.advisorRoute
        self.responsesClient = responsesClient ?? ResponsesClient(endpoint: URL(string: configuration.responsesURL)!)
        self.sessionLoader = sessionLoader ?? SubscriptionSessionLoader()
        self.inputTokenCounter = inputTokenCounter ?? AnthropicInputTokenCounter()
        self.installationID = UUID().uuidString.lowercased()
    }

    public func handleMessages(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionHeader = request.headers["x-claude-code-session-id"]   // may be nil
        let sessionID = sessionHeader ?? UUID().uuidString.lowercased()    // keep existing UUID fallback for trace / pendingToolTurns keys
        let startedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        do {
            let anthropicRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let credentials = try await sessionLoader.loadCurrent()

            switch try await prepareTurn(
                request: anthropicRequest,
                sessionID: sessionID,
                sessionHeader: sessionHeader
            ) {
            case .rejection(let rejection):
                await logRequestOutcome(
                    sessionID: sessionID,
                    response: rejection.response,
                    startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                    result: "preflight_rejected",
                    errorType: rejection.errorType,
                    errorMessage: rejection.errorMessage
                )
                return rejection.response
            case .turn(let preparedTurn):
                let contentBlockTypes = Self.contentBlockTypes(in: anthropicRequest.messages)
                // Emit anthropic_in with routing fields after resolvedRoute is available.
                await TraceLogger.shared.log(JSONObject.from([
                    "stage": .string("anthropic_in"),
                    "session_id": .string(sessionID),
                    "model": .string(anthropicRequest.model),
                    "claude_model": .string(preparedTurn.anthropicModel),
                    "upstream_model": .string(preparedTurn.resolvedRoute.route.upstreamModel),
                    "reasoning_effort": .string(preparedTurn.resolvedRoute.route.reasoningEffort),
                    "text_verbosity": .string(preparedTurn.resolvedRoute.route.textVerbosity),
                    "resolved_route_match": .string(preparedTurn.resolvedRoute.matchLabel),
                    "message_count": .number(Double(anthropicRequest.messages.count)),
                    "tool_count": .number(Double(anthropicRequest.tools?.count ?? 0)),
                    "content_block_types": .array(contentBlockTypes.map(JSONValue.string)),
                    "has_image": .bool(contentBlockTypes.contains("image")),
                    "has_tool_result": .bool(contentBlockTypes.contains("tool_result")),
                ]))
                // Preflight: establish the first /responses stream before flushing 200 headers.
                // If 401, refresh once and retry. Second 401 or refresh failure → return 503.
                // See: docs/06-plans/2026-04-23-phase5-auth-refresh-count-tokens-plan.md Task 5.
                var activeCredentials = credentials
                var initialStream: AsyncThrowingStream<JSONObject, Error>
                do {
                    initialStream = try await responsesClient.streamEvents(
                        request: preparedTurn.firstPassPayload,
                        credentials: activeCredentials
                    )
                } catch let error as ResponsesHTTPError where error.statusCode == 401 {
                    await TraceLogger.shared.log(JSONObject.from([
                        "stage": .string("subscription_refresh_attempt"),
                        "session_id": .string(sessionID),
                        "trigger": .string("upstream_401"),
                    ]))
                    do {
                        activeCredentials = try await sessionLoader.refreshAndReload()
                    } catch let refreshError {
                        let errorType: String
                        if refreshError is AuthRefreshError {
                            errorType = "auth_refresh_error"
                        } else if refreshError is SubscriptionSessionError {
                            errorType = "subscription_session_error"
                        } else if refreshError is URLError {
                            errorType = "network_error"
                        } else {
                            errorType = "unknown"
                        }
                        await TraceLogger.shared.log(JSONObject.from([
                            "stage": .string("subscription_refresh_failure"),
                            "session_id": .string(sessionID),
                            "error_type": .string(errorType),
                            "error_message": .string(String(String(describing: refreshError).prefix(200))),
                        ]))
                        let response = anthropicError(
                            statusCode: 503,
                            errorType: "authentication_error",
                            message: "Subscription authorization expired; refresh failed: \(refreshError.localizedDescription)"
                        )
                        await logRequestOutcome(sessionID: sessionID, response: response,
                            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                            result: "refresh_failed", errorType: "authentication_error",
                            errorMessage: refreshError.localizedDescription)
                        return response
                    }
                    await TraceLogger.shared.log(JSONObject.from([
                        "stage": .string("subscription_refresh_success"),
                        "session_id": .string(sessionID),
                        "access_token_suffix": .string(String(activeCredentials.accessToken.suffix(4))),
                        "last_refresh": activeCredentials.lastRefresh.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                    ]))
                    // Second attempt; if this also 401s, surface as 503.
                    do {
                        initialStream = try await responsesClient.streamEvents(
                            request: preparedTurn.firstPassPayload,
                            credentials: activeCredentials
                        )
                    } catch let retryError as ResponsesHTTPError where retryError.statusCode == 401 {
                        let response = anthropicError(
                            statusCode: 503,
                            errorType: "authentication_error",
                            message: "Subscription authorization expired after refresh"
                        )
                        await logRequestOutcome(sessionID: sessionID, response: response,
                            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                            result: "double_401", errorType: "authentication_error",
                            errorMessage: "upstream rejected refreshed token")
                        return response
                    }
                }
                // (Other errors — 5xx, network — fall through to the existing outer catch
                //  which maps them to Anthropic api_error responses.)
                return HTTPResponse(
                    statusCode: 200, reasonPhrase: "OK",
                    headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                    stream: { [self, preparedTurn, sessionID, activeCredentials, initialStream] writer in
                        try await self.runPreparedTurn(
                            writer: writer, preparedTurn: preparedTurn, sessionID: sessionID,
                            credentials: activeCredentials, startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                            initialStream: initialStream
                        )
                    }
                )
            }
        } catch let error as ResponsesHTTPError {
            let response = anthropicError(
                statusCode: error.statusCode,
                errorType: error.statusCode >= 500 ? "api_error" : "invalid_request_error",
                message: error.body
            )
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
            let response = anthropicError(
                statusCode: 503,
                errorType: "api_error",
                message: error.localizedDescription
            )
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
            let response = anthropicError(
                statusCode: 400,
                errorType: "invalid_request_error",
                message: error.localizedDescription
            )
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

    /// Handles /v1/messages/count_tokens by routing the Anthropic request through
    /// the IR codec path (matching prepareTurn's token-counting) and returning
    /// the BPE-encoded token count. DP-001 Chosen: C — no inline conversion.
    public func handleCountTokens(_ request: HTTPRequest) async -> HTTPResponse {
        let startTime = ContinuousClock.now

        await TraceLogger.shared.log(JSONObject.from([
            "stage": .string("count_tokens_in"),
            "path": .string(request.path),
            "body_size": .number(Double(request.body.count)),
        ]))

        do {
            let anthropicRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let countablePayload = buildCountablePayload(from: anthropicRequest)
            let count = try await inputTokenCounter.countInputTokens(for: countablePayload)
            let elapsed = startTime.duration(to: .now)

            await TraceLogger.shared.log(JSONObject.from([
                "stage": .string("count_tokens_out"),
                "input_tokens": .number(Double(count)),
                "duration_ms": .number(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15 * 1000),
            ]))

            return try HTTPResponse.json(value: CountTokensResult(input_tokens: count))
        } catch {
            return anthropicError(
                statusCode: 400,
                errorType: "invalid_request_error",
                message: "Count tokens: \(error.localizedDescription)"
            )
        }
    }

    /// Builds the responses-shape payload used for BPE token counting.
    /// Must use the same IR codec path as prepareTurn so that count_tokens output
    /// is byte-identical to the bridge's messageStartInputTokens computation.
    private func buildCountablePayload(from request: AnthropicMessagesRequest) -> JSONObject {
        let requestIR: [IRMessage] = request.messages.map { msg in
            IRMessage(
                role: msg.role,
                content: IRAnthropicCodec.decodeRequestBlocks(msg.content)
            )
        }
        let instructions = joinedSystemText(from: request.system ?? [])
        let convertedTools = (try? convertTools(request.tools ?? []))?.convertedTools ?? []
        return JSONObject.from([
            "instructions": .string(instructions),
            "input": .array(IRResponsesCodec.encodeFullHistory(requestIR)),
            "tools": .array(convertedTools.map(JSONValue.object)),
        ])
    }

    public func doctorStatus() async -> BridgeDoctorStatus {
        do {
            let credentials = try await sessionLoader.loadCurrent()
            return BridgeDoctorStatus(
                authState: .ready,
                chatGPTAuthenticated: true,
                accountIDSuffix: String(credentials.accountID.suffix(6)),
                authError: nil,
                lastRefresh: credentials.lastRefresh,
                hasRefreshToken: credentials.refreshToken != nil,
                accessTokenPreview: credentials.accessTokenPreview
            )
        } catch let error as SubscriptionSessionError {
            return BridgeDoctorStatus(
                authState: error.authState,
                chatGPTAuthenticated: false,
                accountIDSuffix: nil,
                authError: error.localizedDescription,
                lastRefresh: nil,
                hasRefreshToken: false,
                accessTokenPreview: nil
            )
        } catch {
            return BridgeDoctorStatus(
                authState: .unknownFailure,
                chatGPTAuthenticated: false,
                accountIDSuffix: nil,
                authError: error.localizedDescription,
                lastRefresh: nil,
                hasRefreshToken: false,
                accessTokenPreview: nil
            )
        }
    }

    public func updateRouting(table: ModelRoutingTable, advisorRoute: ModelRoute) async {
        self.routingTable = table
        self.advisorRoute = advisorRoute
        await TraceLogger.shared.log(JSONObject.from([
            "stage": .string("routing_hot_reload"),
            "rules_count": .number(Double(table.rules.count)),
            "fallback_upstream": .string(table.fallback.upstreamModel),
            "advisor_upstream": .string(advisorRoute.upstreamModel),
        ]))
    }

    // MARK: - Streaming turn execution

    private func prepareTurn(
        request: AnthropicMessagesRequest,
        sessionID: String,
        sessionHeader: String?
    ) async throws -> PreparedTurnResult {
        let requestIR = request.messages.map { IRMessage(role: $0.role, content: IRAnthropicCodec.decodeRequestBlocks($0.content)) }
        let continuationHistory = ToolContinuationHistory.analyze(requestIR)
        let tools = try convertTools(request.tools ?? [])
        let requestEffectiveTools = applySkillWorkflowToolPolicy(
            to: tools,
            requestIR: requestIR,
            activeContinuation: continuationHistory.activeContinuation
        )
        let instructions = joinedSystemText(from: request.system ?? [])
        let cacheKey = PromptCacheKey.stable(
            sessionID: sessionHeader,
            instructions: instructions,
            firstUserMessageText: firstUserMessageText(from: requestIR)
        )
        let incomingToolResultIDs = continuationHistory.trailingToolResultIDs
        let pending = readPending(sessionID: sessionID)

        if let activeContinuation = continuationHistory.activeContinuation {
            let continuationInput = IRResponsesCodec.encodeFullHistory(activeContinuation.continuationMessages)

            if let pending {
                let pendingEffectiveTools = applySkillWorkflowToolPolicy(
                    to: ConvertedTools(convertedTools: pending.convertedTools, advisorEnabled: pending.advisorEnabled),
                    requestIR: requestIR,
                    activeContinuation: activeContinuation
                )
                let pendingReplayCallIDs = replayToolUseIDs(from: pending.replayIR)
                switch continuationHistory.relation(toCachedCallIDs: pendingReplayCallIDs) {
                case .matchesActiveTail:
                    let resolutionSource: String
                    if let requestTools = request.tools, !requestTools.isEmpty {
                        let continuationFingerprint = ToolContractFingerprint.stable(tools.convertedTools)
                        resolutionSource = continuationFingerprint == pending.toolContractFingerprint
                            ? "pending_cache_match"
                            : "pending_cache_match_tool_drift_ignored"
                    } else {
                        resolutionSource = "pending_cache_match"
                    }

                    let replayInput = IRResponsesCodec.encodeReplayBlocks(pending.replayIR)
                    let continuationPayload = makeResponsesPayload(
                        route: pending.resolvedRoute.route,
                        instructions: "",
                        input: replayInput + continuationInput,
                        tools: pendingEffectiveTools.current.convertedTools,
                        toolChoice: .string("auto"),
                        promptCacheKey: cacheKey
                    )

                    await logContinuationDispatch(
                        sessionID: sessionID,
                        claudeModel: pending.anthropicModel,
                        route: pending.resolvedRoute.route,
                        matchLabel: pending.resolvedRoute.matchLabel,
                        promptCacheKey: cacheKey,
                        payload: continuationPayload,
                        resolutionSource: resolutionSource,
                        activeToolResultIDs: activeContinuation.toolResultIDs,
                        activeReplayCallIDs: activeContinuation.callIDs,
                        pendingReplayCallIDs: pendingReplayCallIDs
                    )

                    return .turn(PreparedTurn(
                        anthropicModel: pending.anthropicModel,
                        requestIR: requestIR,
                        instructions: instructions,
                        advisorEnabled: pendingEffectiveTools.current.advisorEnabled,
                        promptCacheKey: cacheKey,
                        firstPassPayload: continuationPayload,
                        messageStartInputTokens: try await inputTokenCounter.countInputTokens(for: continuationPayload),
                        resolvedRoute: pending.resolvedRoute,
                        pending: pending,
                        storedTools: pendingEffectiveTools.pending.convertedTools,
                        toolContractFingerprint: pending.toolContractFingerprint,
                        pendingMutation: .none
                    ))

                case .resolvedInHistory, .absentFromTail:
                    removePending(sessionID: sessionID)
                    await logCacheHealing(
                        sessionID: sessionID,
                        resolutionSource: "pending_cache_stale_cleared",
                        activeToolResultIDs: activeContinuation.toolResultIDs,
                        activeReplayCallIDs: activeContinuation.callIDs,
                        pendingReplayCallIDs: pendingReplayCallIDs
                    )

                    guard let requestTools = request.tools, !requestTools.isEmpty else {
                        return await preflightReject(
                            statusCode: 400,
                            errorType: "invalid_request_error",
                            message: "tool_result continuation missing tools required for history recovery",
                            sessionID: sessionID,
                            incomingToolResultIDs: incomingToolResultIDs,
                            pendingReplayCallIDs: pendingReplayCallIDs
                        )
                    }

                    let resolvedRoute = routingTable.resolveWithMatch(for: request.model)
                    let replayInput = IRResponsesCodec.encodeReplayBlocks(activeContinuation.replayIR)
                    let continuationPayload = makeResponsesPayload(
                        route: resolvedRoute.route,
                        instructions: "",
                        input: replayInput + continuationInput,
                        tools: requestEffectiveTools.current.convertedTools,
                        toolChoice: .string("auto"),
                        promptCacheKey: cacheKey
                    )

                    await logContinuationDispatch(
                        sessionID: sessionID,
                        claudeModel: request.model,
                        route: resolvedRoute.route,
                        matchLabel: resolvedRoute.matchLabel,
                        promptCacheKey: cacheKey,
                        payload: continuationPayload,
                        resolutionSource: "pending_cache_stale_cleared",
                        activeToolResultIDs: activeContinuation.toolResultIDs,
                        activeReplayCallIDs: activeContinuation.callIDs,
                        pendingReplayCallIDs: pendingReplayCallIDs
                    )

                    return .turn(PreparedTurn(
                        anthropicModel: request.model,
                        requestIR: requestIR,
                        instructions: instructions,
                        advisorEnabled: requestEffectiveTools.current.advisorEnabled,
                        promptCacheKey: cacheKey,
                        firstPassPayload: continuationPayload,
                        messageStartInputTokens: try await inputTokenCounter.countInputTokens(for: continuationPayload),
                        resolvedRoute: resolvedRoute,
                        pending: nil,
                        storedTools: requestEffectiveTools.pending.convertedTools,
                        toolContractFingerprint: ToolContractFingerprint.stable(tools.convertedTools),
                        pendingMutation: .clearedStalePending
                    ))
                }
            }

            guard let requestTools = request.tools, !requestTools.isEmpty else {
                return await preflightReject(
                    statusCode: 400,
                    errorType: "invalid_request_error",
                    message: "tool_result continuation missing tools required for history recovery",
                    sessionID: sessionID,
                    incomingToolResultIDs: incomingToolResultIDs,
                    pendingReplayCallIDs: []
                )
            }
            _ = requestTools

            let resolvedRoute = routingTable.resolveWithMatch(for: request.model)
            let replayInput = IRResponsesCodec.encodeReplayBlocks(activeContinuation.replayIR)
            let continuationPayload = makeResponsesPayload(
                route: resolvedRoute.route,
                instructions: "",
                input: replayInput + continuationInput,
                tools: requestEffectiveTools.current.convertedTools,
                toolChoice: .string("auto"),
                promptCacheKey: cacheKey
            )

            await logContinuationDispatch(
                sessionID: sessionID,
                claudeModel: request.model,
                route: resolvedRoute.route,
                matchLabel: resolvedRoute.matchLabel,
                promptCacheKey: cacheKey,
                payload: continuationPayload,
                resolutionSource: "history_recovered",
                activeToolResultIDs: activeContinuation.toolResultIDs,
                activeReplayCallIDs: activeContinuation.callIDs,
                pendingReplayCallIDs: []
            )

            return .turn(PreparedTurn(
                anthropicModel: request.model,
                requestIR: requestIR,
                instructions: instructions,
                advisorEnabled: requestEffectiveTools.current.advisorEnabled,
                promptCacheKey: cacheKey,
                firstPassPayload: continuationPayload,
                messageStartInputTokens: try await inputTokenCounter.countInputTokens(for: continuationPayload),
                resolvedRoute: resolvedRoute,
                pending: nil,
                storedTools: requestEffectiveTools.pending.convertedTools,
                toolContractFingerprint: ToolContractFingerprint.stable(tools.convertedTools),
                pendingMutation: .none
            ))
        }

        if !incomingToolResultIDs.isEmpty {
            return await preflightReject(
                statusCode: 400,
                errorType: "invalid_request_error",
                message: "orphaned tool_result continuation",
                sessionID: sessionID,
                incomingToolResultIDs: incomingToolResultIDs,
                pendingReplayCallIDs: pending.map { replayToolUseIDs(from: $0.replayIR) } ?? []
            )
        }

        var pendingMutation: PendingStateMutation = .none
        if let pending {
            let pendingReplayCallIDs = replayToolUseIDs(from: pending.replayIR)
            switch continuationHistory.relation(toCachedCallIDs: pendingReplayCallIDs) {
            case .resolvedInHistory:
                removePending(sessionID: sessionID)
                pendingMutation = .clearedStalePending
                await logCacheHealing(
                    sessionID: sessionID,
                    resolutionSource: "pending_cache_stale_cleared",
                    activeToolResultIDs: [],
                    activeReplayCallIDs: [],
                    pendingReplayCallIDs: pendingReplayCallIDs
                )
            case .matchesActiveTail, .absentFromTail:
                return await preflightReject(
                    statusCode: 400,
                    errorType: "invalid_request_error",
                    message: "pending tool turn requires matching tool_result continuation",
                    sessionID: sessionID,
                    incomingToolResultIDs: incomingToolResultIDs,
                    pendingReplayCallIDs: pendingReplayCallIDs
                )
            }
        }

        let resolvedRoute = routingTable.resolveWithMatch(for: request.model)
        let initialPayload = makeResponsesPayload(
            route: resolvedRoute.route,
            instructions: instructions,
            input: IRResponsesCodec.encodeFullHistory(requestIR),
            tools: requestEffectiveTools.current.convertedTools,
            toolChoice: .string("auto"),
            promptCacheKey: cacheKey
        )
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("responses_out_initial"),
                "session_id": .string(sessionID),
                "claude_model": .string(request.model),
                "upstream_model": .string(resolvedRoute.route.upstreamModel),
                "reasoning_effort": .string(resolvedRoute.route.reasoningEffort),
                "text_verbosity": .string(resolvedRoute.route.textVerbosity),
                "resolved_route_match": .string(resolvedRoute.matchLabel),
                "prompt_cache_key": .string(cacheKey),
                "tool_names": .array(requestEffectiveTools.current.convertedTools.compactMap { $0.string("name").map(JSONValue.string) }),
                "advisor_enabled": .bool(requestEffectiveTools.current.advisorEnabled),
                "tool_policy": requestEffectiveTools.policyLabel.map(JSONValue.string) ?? .null,
                "continuation_resolution_source": pendingMutation == .clearedStalePending ? .string("pending_cache_stale_cleared") : .null,
            ])
        )
        return .turn(PreparedTurn(
            anthropicModel: request.model,
            requestIR: requestIR,
            instructions: instructions,
            advisorEnabled: requestEffectiveTools.current.advisorEnabled,
            promptCacheKey: cacheKey,
            firstPassPayload: initialPayload,
            messageStartInputTokens: try await inputTokenCounter.countInputTokens(for: initialPayload),
            resolvedRoute: resolvedRoute,
            pending: nil,
            storedTools: requestEffectiveTools.pending.convertedTools,
            toolContractFingerprint: ToolContractFingerprint.stable(tools.convertedTools),
            pendingMutation: pendingMutation
        ))
    }

    /// Executes one preflighted streaming turn: streams from /responses, encodes SSE
    /// events into the HTTP body writer, handles advisor sub-calls, and manages
    /// pendingToolTurns for tool-use continuation.
    /// The `initialStream` is the already-established AsyncThrowingStream from the
    /// preflight streamEvents call in handleMessages (Task 5 architectural rewrite).
    private func runPreparedTurn(
        writer: HTTPBodyWriter,
        preparedTurn: PreparedTurn,
        sessionID: String,
        credentials: SubscriptionCredentials,
        startedAtUptimeNanoseconds: UInt64,
        initialStream: AsyncThrowingStream<JSONObject, Error>
    ) async throws {
        let encoder = AnthropicSSEEncoder(anthropicModel: preparedTurn.anthropicModel, writer: writer)
        let pendingMutationTracker = PendingMutationTracker(initialValue: preparedTurn.pendingMutation)
        try await encoder.startMessage(initialInputTokens: preparedTurn.messageStartInputTokens)

        do {
            let stream = initialStream
            let (sawAdvisorCall, outputIRBlocks, finalUsage) = try await processUpstreamStream(
                stream: stream,
                encoder: encoder,
                advisorEnabled: preparedTurn.advisorEnabled
            )

            try await handleOutputBlocks(
                anthropicModel: preparedTurn.anthropicModel,
                resolvedRoute: preparedTurn.resolvedRoute,
                outputIRBlocks: outputIRBlocks,
                sawAdvisorCall: sawAdvisorCall,
                advisorEnabled: preparedTurn.advisorEnabled,
                pending: preparedTurn.pending,
                finalUsage: finalUsage,
                sessionID: sessionID,
                requestIR: preparedTurn.requestIR,
                promptCacheKey: preparedTurn.promptCacheKey,
                credentials: credentials,
                writer: writer,
                encoder: encoder,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                instructions: preparedTurn.instructions,
                historyIR: preparedTurn.requestIR,
                storedTools: preparedTurn.storedTools,
                toolContractFingerprint: preparedTurn.toolContractFingerprint,
                pendingMutationTracker: pendingMutationTracker
            )
        } catch {
            if pendingMutationTracker.value == .storedPending {
                removePending(sessionID: sessionID)
            }
            try? await encoder.emitTextDelta("\n[upstream error: \(error.localizedDescription)]")
            try? await encoder.finish(stopReasonHint: .endTurn)
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("anthropic_out"),
                    "session_id": .string(sessionID),
                    "status_code": .number(200),
                    "result": .string("stream_aborted"),
                    "error_type": .string("stream_aborted"),
                    "error_message": .string(error.localizedDescription),
                    "pending_mutation_state": .string(pendingMutationTracker.value.rawValue),
                    "claude_model": .string(preparedTurn.anthropicModel),
                    "upstream_model": .string(preparedTurn.resolvedRoute.route.upstreamModel),
                    "reasoning_effort": .string(preparedTurn.resolvedRoute.route.reasoningEffort),
                    "text_verbosity": .string(preparedTurn.resolvedRoute.route.textVerbosity),
                    "resolved_route_match": .string(preparedTurn.resolvedRoute.matchLabel),
                ])
            )
            throw error
        }
    }

    /// Drives the upstream AsyncThrowingStream: decodes each /responses SSE event to
    /// IR and immediately emits the corresponding Anthropic SSE frames.
    /// Returns the tuple: (advisor call found, all output IR blocks, final usage).
    private func processUpstreamStream(
        stream: AsyncThrowingStream<JSONObject, Error>,
        encoder: AnthropicSSEEncoder,
        advisorEnabled: Bool
    ) async throws -> (sawAdvisorCall: (id: String, argumentsJSON: String)?, outputIRBlocks: [IRBlock], finalUsage: (input: Int, output: Int)) {
        var sawAdvisorCall: (id: String, argumentsJSON: String)? = nil
        var outputIRBlocks: [IRBlock] = []
        var finalUsage: (input: Int, output: Int) = (0, 0)
        var inStreamingThinking = false

        for try await event in stream {
            guard let eventType = event.string("type") else { continue }

            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("responses_in_event"),
                    "event_type": .string(eventType),
                ])
            )

            switch eventType {
            case "response.reasoning_summary_part.added":
                try await encoder.startThinkingBlock()
                inStreamingThinking = true

            case "response.reasoning_summary_text.delta":
                if let delta = event.string("delta") {
                    try await encoder.emitThinkingDelta(delta)
                }

            case "response.reasoning_summary_part.done":
                break

            case "response.output_text.delta":
                if let delta = event.string("delta") {
                    // emitTextDelta handles the transition itself: if the current block
                    // is non-text (e.g. tool_use just emitted), it calls closeOpenBlock
                    // internally and opens a fresh text block. If the current block is
                    // already text, it appends to it. Calling closeOpenBlock here
                    // unconditionally would fragment consecutive text deltas into
                    // separate content blocks (indices 1, 2, 3…) instead of one.
                    try await encoder.emitTextDelta(delta)
                }

            case "response.output_item.done":
                guard let item = event.object("item") else { break }
                if let webSearch = Self.decodeWebSearchCall(item) {
                    let serverToolUse = IRBlock.serverToolUse(
                        id: webSearch.id,
                        name: "web_search",
                        input: webSearch.input
                    )
                    let toolResult = IRBlock.webSearchToolResult(
                        toolUseID: webSearch.id,
                        content: webSearch.results
                    )
                    outputIRBlocks.append(serverToolUse)
                    outputIRBlocks.append(toolResult)
                    try await encoder.emitServerToolUseBlock(
                        id: webSearch.id,
                        name: "web_search",
                        input: webSearch.input
                    )
                    try await encoder.emitWebSearchToolResultBlock(
                        toolUseID: webSearch.id,
                        content: webSearch.results
                    )
                    break
                }
                guard let ir = IRResponsesCodec.decodeOutputItem(item) else { break }
                outputIRBlocks.append(ir)

                switch ir {
                case .text:
                    // Text delta already emitted via output_text.delta; close the block.
                    try await encoder.closeOpenBlock()

                case .toolUse(let id, let name, _):
                    if name == "advisor" && advisorEnabled {
                        sawAdvisorCall = (id, item.string("arguments") ?? "{}")
                    } else {
                        try await encoder.emitToolUseBlock(
                            id: id,
                            name: name,
                            argumentsJSON: item.string("arguments") ?? "{}"
                        )
                    }

                case .thinking(let enc, let sum):
                    if inStreamingThinking {
                        // Already streamed summary via reasoning_summary_text.delta — just
                        // emit signature_delta and close. `sum` here is the upstream-buffered
                        // flattened summary; we don't re-emit it because deltas already did.
                        if let enc, !enc.isEmpty {
                            try await encoder.emitSignatureDelta(encryptedContent: enc)
                        }
                        try await encoder.closeOpenBlock()
                        inStreamingThinking = false
                    } else {
                        // Fallback: no summary stream events observed (e.g., older upstream
                        // or effort level where summary is not emitted).
                        try await encoder.emitThinkingBlock(encryptedContent: enc, summary: sum)
                    }

                default:
                    break
                }

            case "response.completed":
                if let usage = event.object("response")?.object("usage") {
                    finalUsage.input = usage["input_tokens"]?.intValue ?? 0
                    finalUsage.output = usage["output_tokens"]?.intValue ?? 0
                }

            default:
                continue
            }
        }

        // Guard against streams that end without output_item.done for the last block.
        try await encoder.closeOpenBlock()
        encoder.updateFinalOutputTokens(finalUsage.output)

        return (sawAdvisorCall, outputIRBlocks, finalUsage)
    }

    /// Routes output IR blocks to: advisor branch, tool-use branch, or text-only branch.
    /// Caller passes the encoder so each branch can call finish() before returning.
    private func handleOutputBlocks(
        anthropicModel: String,
        resolvedRoute: ResolvedRoute,
        outputIRBlocks: [IRBlock],
        sawAdvisorCall: (id: String, argumentsJSON: String)?,
        advisorEnabled: Bool,
        pending: PendingToolTurn?,
        finalUsage: (input: Int, output: Int),
        sessionID: String,
        requestIR: [IRMessage],
        promptCacheKey: String,
        credentials: SubscriptionCredentials,
        writer: HTTPBodyWriter,
        encoder: AnthropicSSEEncoder,
        startedAtUptimeNanoseconds: UInt64,
        instructions: String,
        historyIR: [IRMessage],
        storedTools: [JSONObject],
        toolContractFingerprint: String,
        pendingMutationTracker: PendingMutationTracker
    ) async throws {
        // Advisor branch.
        if advisorEnabled, let advisorCall = sawAdvisorCall {
            try await runAdvisorSubcallAndSecondPass(
                anthropicModel: anthropicModel,
                resolvedRoute: resolvedRoute,
                advisorCallID: advisorCall.id,
                outputIRBlocks: outputIRBlocks,
                pending: pending,
                finalUsage: finalUsage,
                sessionID: sessionID,
                requestIR: requestIR,
                promptCacheKey: promptCacheKey,
                credentials: credentials,
                writer: writer,
                encoder: encoder,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                instructions: instructions,
                historyIR: historyIR,
                storedTools: storedTools,
                toolContractFingerprint: toolContractFingerprint,
                pendingMutationTracker: pendingMutationTracker
            )
            return
        }

        // Tool-use branch (non-advisor or advisor branch not triggered).
        //
        // A turn is a "tool-use turn" only if upstream actually emitted a tool_use block.
        // Thinking-only turns (reasoning block with no tool_use) must use the text/end_turn
        // branch — sending `stop_reason: tool_use` without a tool_use content block causes
        // Claude Code CLI to abort the connection with "socket closed unexpectedly".
        let hasToolUse = outputIRBlocks.contains { ir in
            if case .toolUse = ir { return true }
            return false
        }
        let replayIR = outputIRBlocks.filter { ir in
            if case .thinking = ir { return true }
            if case .toolUse = ir { return true }
            return false
        }

        if hasToolUse {
            storePending(PendingToolTurn(
                anthropicModel: anthropicModel,
                convertedTools: storedTools,
                toolContractFingerprint: toolContractFingerprint,
                replayIR: replayIR,
                advisorEnabled: advisorEnabled,
                resolvedRoute: resolvedRoute,
                lastAccessedAt: Date()
            ), sessionID: sessionID)
            pendingMutationTracker.value = .storedPending
            await TraceLogger.shared.log(
                JSONObject.from([
                    "stage": .string("pending_tool_turn_store"),
                    "session_id": .string(sessionID),
                    "replay_item_types": .array(replayIR.map { ir -> JSONValue in
                        switch ir {
                        case .text: return .string("text")
                        case .image: return .string("image")
                        case .toolUse: return .string("tool_use")
                        case .toolResult: return .string("tool_result")
                        case .thinking: return .string("thinking")
                        case .serverToolUse: return .string("server_tool_use")
                        case .advisorToolResult: return .string("advisor_tool_result")
                        case .webSearchToolResult: return .string("web_search_tool_result")
                        }
                    }),
                ])
            )
            try await encoder.finish(stopReasonHint: .toolUse)
            return
        }

        // Text-only branch.
        removePending(sessionID: sessionID)
        pendingMutationTracker.value = .removedPending
        try await encoder.finish(stopReasonHint: .endTurn)
        await logRequestOutcome(
            sessionID: sessionID,
            response: HTTPResponse(statusCode: 200, reasonPhrase: "OK"),
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
            result: "success",
            claudeModel: anthropicModel,
            resolvedRoute: resolvedRoute
        )
    }

    /// Handles the advisor sub-call, synthesises server_tool_use + advisor_tool_result,
    /// then issues a second /responses pass and finishes.
    ///
    /// Blocks from the first pass (text / thinking / non-advisor tool_use) were
    /// already emitted during `processUpstreamStream`. Only the advisor
    /// function_call was withheld (its `.toolUse` entry is in outputIRBlocks but
    /// was never sent to the wire). We emit the synthetic server_tool_use +
    /// advisor_tool_result in its place.
    private func runAdvisorSubcallAndSecondPass(
        anthropicModel: String,
        resolvedRoute: ResolvedRoute,
        advisorCallID: String,
        outputIRBlocks: [IRBlock],
        pending: PendingToolTurn?,
        finalUsage: (input: Int, output: Int),
        sessionID: String,
        requestIR: [IRMessage],
        promptCacheKey: String,
        credentials: SubscriptionCredentials,
        writer: HTTPBodyWriter,
        encoder: AnthropicSSEEncoder,
        startedAtUptimeNanoseconds: UInt64,
        instructions: String,
        historyIR: [IRMessage],
        storedTools: [JSONObject],
        toolContractFingerprint: String,
        pendingMutationTracker: PendingMutationTracker
    ) async throws {

        // Synthesise server_tool_use (represents the advisor call to the client).
        try await encoder.emitServerToolUseBlock(id: advisorCallID, name: "advisor", input: JSONObject())

        // Advisor sub-call.
        let advisorText: String
        do {
            advisorText = try await runAdvisorSubcall(
                credentials: credentials,
                instructions: instructions,
                historyIR: historyIR,
                messageLimit: configuration.advisorContextMessageLimit,
                promptCacheKey: promptCacheKey
            )
        } catch {
            // Advisory: sub-call failure does not abort the main turn.
            try await encoder.emitAdvisorToolResultBlock(
                toolUseID: advisorCallID,
                text: "[advisor unavailable: \(error.localizedDescription)]"
            )
            removePending(sessionID: sessionID)
            pendingMutationTracker.value = .removedPending
            try await encoder.finish(stopReasonHint: .endTurn)
            return
        }

        // Synthesise advisor_tool_result.
        try await encoder.emitAdvisorToolResultBlock(toolUseID: advisorCallID, text: advisorText)

        // Build second-pass input.
        let replayInput = IRResponsesCodec.encodeReplayBlocks(outputIRBlocks.filter { block in
            if case .thinking = block { return true }
            if case .toolUse = block { return true }
            return false
        })
        let advisorOutputItem = JSONObject([
            "type": .string("function_call_output"),
            "call_id": .string(advisorCallID),
            "output": .string(advisorText),
        ])

        let secondPayload = makeResponsesPayload(
            route: resolvedRoute.route,
            instructions: "",
            input: replayInput + [.object(advisorOutputItem)],
            tools: storedTools,
            toolChoice: .string("auto"),
            promptCacheKey: promptCacheKey
        )

        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("responses_out_advisor_continuation"),
                "session_id": .string(sessionID),
                "claude_model": .string(anthropicModel),
                "upstream_model": .string(resolvedRoute.route.upstreamModel),
                "reasoning_effort": .string(resolvedRoute.route.reasoningEffort),
                "text_verbosity": .string(resolvedRoute.route.textVerbosity),
                "resolved_route_match": .string(resolvedRoute.matchLabel),
                "prompt_cache_key": .string(promptCacheKey),
            ])
        )

        let secondStream = try await responsesClient.streamEvents(request: secondPayload, credentials: credentials)
        let (_, secondOutputIRBlocks, secondUsage) = try await processUpstreamStream(
            stream: secondStream,
            encoder: encoder,
            advisorEnabled: false   // Disable advisor detection in second pass to avoid loops.
        )

        encoder.updateFinalOutputTokens(secondUsage.output)

        // Check if second pass has non-advisor tool uses.
        let nonAdvisorReplays = secondOutputIRBlocks.filter { block in
            if case .toolUse(_, let name, _) = block {
                return name != "advisor"
            }
            return false
        }
        if !nonAdvisorReplays.isEmpty {
            let replayIR = secondOutputIRBlocks.filter { block in
                if case .thinking = block { return true }
                if case .toolUse = block { return true }
                return false
            }
            storePending(PendingToolTurn(
                anthropicModel: anthropicModel,
                convertedTools: storedTools,
                toolContractFingerprint: toolContractFingerprint,
                replayIR: replayIR,
                advisorEnabled: false,
                resolvedRoute: resolvedRoute,
                lastAccessedAt: Date()
            ), sessionID: sessionID)
            pendingMutationTracker.value = .storedPending
            try await encoder.finish(stopReasonHint: .toolUse)
        } else {
            removePending(sessionID: sessionID)
            pendingMutationTracker.value = .removedPending
            try await encoder.finish(stopReasonHint: .endTurn)
        }

        await logRequestOutcome(
            sessionID: sessionID,
            response: HTTPResponse(statusCode: 200, reasonPhrase: "OK"),
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
            result: "advisor_or_tools",
            claudeModel: anthropicModel,
            resolvedRoute: resolvedRoute
        )
    }

    // MARK: - Helpers (preserved from original)

    private func joinedSystemText(from blocks: [JSONObject]) -> String {
        blocks.compactMap { block in
            guard block.string("type") == "text" else { return nil }
            return block.string("text")
        }
        .joined(separator: "\n\n")
    }

    private func firstUserMessageText(from messages: [IRMessage]) -> String {
        for message in messages where message.role == "user" {
            for block in message.content {
                if case .text(let s) = block, !s.isEmpty { return s }
            }
        }
        return ""
    }

    nonisolated private static func contentBlockTypes(in messages: [AnthropicMessage]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for message in messages {
            collectContentBlockTypes(from: message.content, seen: &seen, ordered: &ordered)
        }
        return ordered
    }

    nonisolated private static func collectContentBlockTypes(
        from blocks: [JSONObject],
        seen: inout Set<String>,
        ordered: inout [String]
    ) {
        for block in blocks {
            if let type = block.string("type"), seen.insert(type).inserted {
                ordered.append(type)
            }

            guard block.string("type") == "tool_result",
                  case .array(let nested)? = block["content"] else {
                continue
            }
            collectContentBlockTypes(
                from: nested.compactMap(\.objectValue),
                seen: &seen,
                ordered: &ordered
            )
        }
    }

    /// Pure computation: no actor state accessed.
    nonisolated private func convertTools(_ tools: [JSONObject]) throws -> ConvertedTools {
        var converted: [JSONObject] = []
        var advisorEnabled = false

        for tool in tools {
            switch tool.string("type") ?? "function" {
            case "function":
                // Accept both "parameters" (Anthropic protocol) and "input_schema"
                // (Responses API / tool_use history) so the conversion works for
                // fresh tool defs and tool_use blocks from conversation history.
                guard
                    let name = tool.string("name"),
                    let description = tool.string("description"),
                    let schema = tool.object("parameters") ?? tool.object("input_schema")
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
                let advisorParams = JSONObject([
                    "type": .string("object"),
                    "properties": .object(JSONObject()),
                    "additionalProperties": .bool(false),
                ])
                converted.append(
                    JSONObject.from([
                        "type": .string("function"),
                        "name": .string("advisor"),
                        "description": .string("Ask a stronger planning advisor for concise strategic guidance."),
                        "strict": .bool(false),
                        "parameters": .object(advisorParams),
                    ])
                )
            case let type where Self.isAnthropicWebSearchToolType(type):
                converted.append(Self.makeResponsesWebSearchTool(from: tool))
            default:
                continue
            }
        }

        return ConvertedTools(convertedTools: converted, advisorEnabled: advisorEnabled)
    }

    nonisolated private func applySkillWorkflowToolPolicy(
        to tools: ConvertedTools,
        requestIR: [IRMessage],
        activeContinuation: ToolContinuationHistory.ContinuationSlice?
    ) -> EffectiveTurnTools {
        guard isLoadedSkillExecutionContext(requestIR) else {
            return EffectiveTurnTools(current: tools, pending: tools, policyLabel: nil)
        }

        let pendingTools = tools.removingTool(named: "advisor", advisorEnabled: false)
        guard isLoadedSkillHandoff(requestIR: requestIR, activeContinuation: activeContinuation) else {
            return EffectiveTurnTools(
                current: pendingTools,
                pending: pendingTools,
                policyLabel: "loaded_skill_context"
            )
        }

        return EffectiveTurnTools(
            current: pendingTools.removingTool(named: "Skill"),
            pending: pendingTools,
            policyLabel: "loaded_skill_handoff"
        )
    }

    nonisolated private func isLoadedSkillExecutionContext(_ messages: [IRMessage]) -> Bool {
        hasLoadedSkillBody(in: messages) && hasSkillInvocationMarker(in: messages)
    }

    nonisolated private func isLoadedSkillHandoff(
        requestIR: [IRMessage],
        activeContinuation: ToolContinuationHistory.ContinuationSlice?
    ) -> Bool {
        if let activeContinuation,
           activeContinuation.replayIR.contains(where: { block in
               if case .toolUse(_, let name, _) = block { return name == "Skill" }
               return false
           }),
           hasLoadedSkillBody(in: activeContinuation.continuationMessages) {
            return true
        }

        let tail = trailingUserMessages(in: requestIR)
        guard !tail.isEmpty, hasLoadedSkillBody(in: tail) else { return false }
        return requestIR.contains { message in
            textFragments(in: message.content).contains { $0.contains("<command-name>/") }
        }
    }

    nonisolated private func trailingUserMessages(in messages: [IRMessage]) -> [IRMessage] {
        var result: [IRMessage] = []
        for message in messages.reversed() {
            guard message.role == "user" else { break }
            result.append(message)
        }
        return result.reversed()
    }

    nonisolated private func hasLoadedSkillBody(in messages: [IRMessage]) -> Bool {
        messages.contains { message in
            textFragments(in: message.content).contains {
                $0.contains("Base directory for this skill:")
            }
        }
    }

    nonisolated private func hasSkillInvocationMarker(in messages: [IRMessage]) -> Bool {
        messages.contains { message in
            textFragments(in: message.content).contains {
                $0.contains("<command-name>/") || $0.contains("Launching skill:")
            }
        }
    }

    nonisolated private func textFragments(in blocks: [IRBlock]) -> [String] {
        var fragments: [String] = []
        for block in blocks {
            switch block {
            case .text(let text):
                fragments.append(text)
            case .toolResult(_, let content):
                fragments.append(contentsOf: textFragments(in: content))
            case .toolUse, .image, .thinking, .serverToolUse, .advisorToolResult, .webSearchToolResult:
                continue
            }
        }
        return fragments
    }

    nonisolated private static func isAnthropicWebSearchToolType(_ type: String) -> Bool {
        type == "web_search" || type.hasPrefix("web_search_")
    }

    nonisolated private static func makeResponsesWebSearchTool(from tool: JSONObject) -> JSONObject {
        var fields: [String: JSONValue] = [
            "type": .string("web_search"),
            "external_web_access": .bool(true),
            "search_content_types": .array([.string("text")]),
        ]

        if let allowedDomains = tool.array("allowed_domains") {
            let domains = allowedDomains.compactMap(\.stringValue).map(JSONValue.string)
            if !domains.isEmpty {
                fields["filters"] = .object(JSONObject.from([
                    "allowed_domains": .array(domains),
                ]))
            }
        }

        if let userLocation = tool.object("user_location") {
            var locationFields: [String: JSONValue] = [:]
            for key in ["type", "city", "region", "country", "timezone"] {
                if let value = userLocation.values[key] {
                    locationFields[key] = value
                }
            }
            if !locationFields.isEmpty {
                fields["user_location"] = .object(JSONObject.from(locationFields))
            }
        }

        return JSONObject.from(fields)
    }

    private func runAdvisorSubcall(
        credentials: SubscriptionCredentials,
        instructions: String,
        historyIR: [IRMessage],
        messageLimit: Int,
        promptCacheKey: String
    ) async throws -> String {
        // Truncate to last N messages (DP-003-P4 Option A).
        let truncated = Array(historyIR.suffix(messageLimit))

        // Build advisor input: flatten each message to a single input_text item per message.
        // Only text blocks are carried to advisor — image/tool/thinking blocks are out of scope
        // for strategic guidance and would balloon advisor payload.
        let advisorMessages: [JSONValue] = truncated.compactMap { message -> JSONValue? in
            let texts = message.content.compactMap { block -> String? in
                if case .text(let s) = block { return s }
                return nil
            }
            guard !texts.isEmpty else { return nil }
            let joined = texts.joined(separator: "\n")
            let contentItem = JSONObject([
                "type": .string(message.role == "assistant" ? "output_text" : "input_text"),
                "text": .string(joined),
            ])
            return .object(JSONObject([
                "type": .string("message"),
                "role": .string(message.role),
                "content": .array([.object(contentItem)]),
            ]))
        }

        let advisorSystem = instructions.isEmpty
            ? "You are a planning advisor. Return only a short guidance paragraph with the best next-step strategy."
            : "You are a planning advisor for the following task. Return only a short guidance paragraph with the best next-step strategy.\n\nOriginal system prompt:\n\(instructions)"

        let advisorPayload = makeResponsesPayload(
            route: self.advisorRoute,
            instructions: advisorSystem,
            input: advisorMessages,
            tools: [],
            toolChoice: .string("none"),
            promptCacheKey: promptCacheKey
        )
        let events = try await responsesClient.perform(request: advisorPayload, credentials: credentials)
        return joinedMessageText(from: events)
    }

    private func joinedMessageText(from events: [JSONObject]) -> String {
        let outputItems = events.compactMap { event -> JSONObject? in
            guard event.string("type") == "response.output_item.done" else { return nil }
            return event.object("item")
        }
        return outputItems
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

    /// Serialises a JSONObject to a JSON string, or nil on failure.
    private func encodeJSONObjectToString(_ object: JSONObject) -> String? {
        guard let data = try? encoder.encode(object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func makeResponsesPayload(
        route: ModelRoute,
        instructions: String,
        input: [JSONValue],
        tools: [JSONObject],
        toolChoice: JSONValue,
        promptCacheKey: String
    ) -> JSONObject {
        let reasoning = JSONObject([
            "effort": .string(route.reasoningEffort),
            "summary": .string("auto"),
        ])
        // reasoning.summary: auto triggers response.reasoning_summary_text.delta events;
        // see docs/research/2026-04-22-image-wire-probe.md Row E/F
        let textVerbosity = JSONObject(["verbosity": .string(route.textVerbosity)])
        let clientMeta = JSONObject(["x-codex-installation-id": .string(installationID)])
        let include = Self.responsesIncludeItems(for: tools)
        return JSONObject.from([
            "model": .string(route.upstreamModel),
            "instructions": .string(instructions),
            "input": .array(input),
            "tools": .array(tools.map(JSONValue.object)),
            "tool_choice": toolChoice,
            "parallel_tool_calls": .bool(true),
            "reasoning": .object(reasoning),
            "store": .bool(false),
            "stream": .bool(true),
            "include": .array(include.map(JSONValue.string)),
            "service_tier": .string("priority"),
            "prompt_cache_key": .string(promptCacheKey),
            "text": .object(textVerbosity),
            "client_metadata": .object(clientMeta),
        ])
    }

    nonisolated private static func responsesIncludeItems(for tools: [JSONObject]) -> [String] {
        var include = ["reasoning.encrypted_content"]
        if tools.contains(where: { $0.string("type") == "web_search" || $0.string("type") == "web_search_preview" }) {
            include.append("web_search_call.action.sources")
        }
        return include
    }

    nonisolated private static func decodeWebSearchCall(_ item: JSONObject) -> (id: String, input: JSONObject, results: [JSONObject])? {
        guard item.string("type") == "web_search_call" else { return nil }
        let id = item.string("id") ?? item.string("call_id") ?? "srvtoolu_\(UUID().uuidString.lowercased())"
        let action = item.object("action") ?? JSONObject()
        let input = webSearchInput(from: action)
        let results = webSearchResults(from: action)
        return (id, input, results)
    }

    nonisolated private static func webSearchInput(from action: JSONObject) -> JSONObject {
        var fields: [String: JSONValue] = [:]
        if let query = action.string("query"), !query.isEmpty {
            fields["query"] = .string(query)
        }
        if let queries = action.array("queries") {
            let stringQueries = queries.compactMap(\.stringValue)
            if !stringQueries.isEmpty {
                fields["queries"] = .array(stringQueries.map(JSONValue.string))
                if fields["query"] == nil {
                    fields["query"] = .string(stringQueries.joined(separator: "\n"))
                }
            }
        }
        for key in ["url", "pattern"] {
            if let value = action.string(key), !value.isEmpty {
                fields[key] = .string(value)
            }
        }
        if fields.isEmpty, let actionType = action.string("type") {
            fields["type"] = .string(actionType)
        }
        return JSONObject.from(fields)
    }

    nonisolated private static func webSearchResults(from action: JSONObject) -> [JSONObject] {
        var sourceObjects = action.array("sources")?.compactMap(\.objectValue) ?? []
        if sourceObjects.isEmpty, let url = action.string("url"), !url.isEmpty {
            sourceObjects = [JSONObject.from(["type": .string("url"), "url": .string(url)])]
        }
        return sourceObjects.compactMap(makeAnthropicWebSearchResult)
    }

    nonisolated private static func makeAnthropicWebSearchResult(from source: JSONObject) -> JSONObject? {
        guard let url = source.string("url") ?? source.string("uri"), !url.isEmpty else {
            return nil
        }
        var fields: [String: JSONValue] = [
            "type": .string("web_search_result"),
            "url": .string(url),
            "title": .string(source.string("title") ?? url),
        ]
        if let pageAge = source.string("page_age"), !pageAge.isEmpty {
            fields["page_age"] = .string(pageAge)
        }
        if let encryptedContent = source.string("encrypted_content"), !encryptedContent.isEmpty {
            fields["encrypted_content"] = .string(encryptedContent)
        }
        return JSONObject.from(fields)
    }

    private func logRequestOutcome(
        sessionID: String,
        response: HTTPResponse,
        startedAtUptimeNanoseconds: UInt64,
        result: String,
        errorType: String? = nil,
        errorMessage: String? = nil,
        claudeModel: String? = nil,
        resolvedRoute: ResolvedRoute? = nil
    ) async {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAtUptimeNanoseconds
        let durationMilliseconds = Int(elapsedNanoseconds / 1_000_000)
        var payload: [String: JSONValue] = [
            "stage": .string("anthropic_out"),
            "session_id": .string(sessionID),
            "status_code": .number(Double(response.statusCode)),
            "result": .string(result),
            "duration_ms": .number(Double(durationMilliseconds)),
            "error_type": errorType.map(JSONValue.string) ?? .null,
            "error_message": errorMessage.map(JSONValue.string) ?? .null,
        ]
        if let claudeModel {
            payload["claude_model"] = .string(claudeModel)
        }
        if let resolvedRoute {
            payload["upstream_model"] = .string(resolvedRoute.route.upstreamModel)
            payload["reasoning_effort"] = .string(resolvedRoute.route.reasoningEffort)
            payload["text_verbosity"] = .string(resolvedRoute.route.textVerbosity)
            payload["resolved_route_match"] = .string(resolvedRoute.matchLabel)
        }
        await TraceLogger.shared.log(JSONObject.from(payload))
    }

    private func anthropicError(statusCode: Int, errorType: String, message: String) -> HTTPResponse {
        let envelope = AnthropicErrorEnvelope(error: AnthropicErrorBody(type: errorType, message: message))
        return try! HTTPResponse.json(
            statusCode: statusCode,
            reasonPhrase: statusCode >= 500 ? "Internal Server Error" : "Bad Request",
            value: envelope
        )
    }

    private func preflightReject(
        statusCode: Int,
        errorType: String,
        message: String,
        sessionID: String,
        incomingToolResultIDs: [String],
        pendingReplayCallIDs: [String]
    ) async -> PreparedTurnResult {
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("continuation_preflight_rejected"),
                "session_id": .string(sessionID),
                "reason": .string(message),
                "incoming_tool_result_ids": .array(incomingToolResultIDs.map(JSONValue.string)),
                "pending_replay_call_ids": .array(pendingReplayCallIDs.map(JSONValue.string)),
            ])
        )
        return .rejection(
            PreflightRejection(
                response: anthropicError(statusCode: statusCode, errorType: errorType, message: message),
                errorType: errorType,
                errorMessage: message
            )
        )
    }

    private func logContinuationDispatch(
        sessionID: String,
        claudeModel: String,
        route: ModelRoute,
        matchLabel: String,
        promptCacheKey: String,
        payload: JSONObject,
        resolutionSource: String,
        activeToolResultIDs: [String],
        activeReplayCallIDs: [String],
        pendingReplayCallIDs: [String]
    ) async {
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("responses_out_continuation"),
                "session_id": .string(sessionID),
                "claude_model": .string(claudeModel),
                "upstream_model": .string(route.upstreamModel),
                "reasoning_effort": .string(route.reasoningEffort),
                "text_verbosity": .string(route.textVerbosity),
                "resolved_route_match": .string(matchLabel),
                "prompt_cache_key": .string(promptCacheKey),
                "continuation_resolution_source": .string(resolutionSource),
                "active_tool_result_ids": .array(activeToolResultIDs.map(JSONValue.string)),
                "active_replay_call_ids": .array(activeReplayCallIDs.map(JSONValue.string)),
                "pending_replay_call_ids": .array(pendingReplayCallIDs.map(JSONValue.string)),
                "input_item_types": .array((payload.array("input") ?? []).compactMap {
                    $0.objectValue?.string("type").map(JSONValue.string)
                }),
                "function_call_ids": .array((payload.array("input") ?? []).compactMap {
                    guard let obj = $0.objectValue else { return nil }
                    let type = obj.string("type") ?? ""
                    guard type == "function_call" || type == "function_call_output" else { return nil }
                    return .string(obj.string("call_id") ?? "<missing>")
                }),
            ])
        )
    }

    private func logCacheHealing(
        sessionID: String,
        resolutionSource: String,
        activeToolResultIDs: [String],
        activeReplayCallIDs: [String],
        pendingReplayCallIDs: [String]
    ) async {
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("continuation_cache_healed"),
                "session_id": .string(sessionID),
                "continuation_resolution_source": .string(resolutionSource),
                "active_tool_result_ids": .array(activeToolResultIDs.map(JSONValue.string)),
                "active_replay_call_ids": .array(activeReplayCallIDs.map(JSONValue.string)),
                "pending_replay_call_ids": .array(pendingReplayCallIDs.map(JSONValue.string)),
            ])
        )
    }

    private func toolResultIDs(from blocks: [IRBlock]) -> [String] {
        blocks.compactMap { block in
            guard case .toolResult(let toolUseID, _) = block else { return nil }
            return toolUseID
        }
    }

    private func replayToolUseIDs(from blocks: [IRBlock]) -> [String] {
        blocks.compactMap { block in
            guard case .toolUse(let id, _, _) = block else { return nil }
            return id
        }
    }

    // MARK: - Types

    private struct ConvertedTools: Sendable {
        let convertedTools: [JSONObject]
        let advisorEnabled: Bool

        func removingTool(named name: String, advisorEnabled advisorOverride: Bool? = nil) -> ConvertedTools {
            ConvertedTools(
                convertedTools: convertedTools.filter { $0.string("name") != name },
                advisorEnabled: advisorOverride ?? advisorEnabled
            )
        }
    }

    private struct EffectiveTurnTools: Sendable {
        let current: ConvertedTools
        let pending: ConvertedTools
        let policyLabel: String?
    }

    private struct PreflightRejection: Sendable {
        let response: HTTPResponse
        let errorType: String
        let errorMessage: String
    }

    private enum PreparedTurnResult: Sendable {
        case rejection(PreflightRejection)
        case turn(PreparedTurn)
    }

    package struct PreparedTurn: Sendable {
        let anthropicModel: String
        let requestIR: [IRMessage]
        let instructions: String
        let advisorEnabled: Bool
        let promptCacheKey: String
        let firstPassPayload: JSONObject
        let messageStartInputTokens: Int
        let resolvedRoute: ResolvedRoute
        let pending: PendingToolTurn?
        let storedTools: [JSONObject]
        let toolContractFingerprint: String
        let pendingMutation: PendingStateMutation
    }

    package struct PendingToolTurn: Sendable {
        let anthropicModel: String
        let convertedTools: [JSONObject]
        let toolContractFingerprint: String
        let replayIR: [IRBlock]
        let advisorEnabled: Bool
        let resolvedRoute: ResolvedRoute   // preserves route consistency across a tool turn
        var lastAccessedAt: Date   // bumped on every read or write
    }

    package enum PendingStateMutation: String, Sendable {
        case none
        case clearedStalePending = "cleared_stale_pending"
        case storedPending = "stored_pending"
        case removedPending = "removed_pending"
    }

    private final class PendingMutationTracker: @unchecked Sendable {
        var value: PendingStateMutation

        init(initialValue: PendingStateMutation) {
            self.value = initialValue
        }
    }

    // MARK: - PendingToolTurn map helpers (DP-004-P4 Option C)

    private func readPending(sessionID: String) -> PendingToolTurn? {
        evictStalePending()
        guard var entry = pendingToolTurns[sessionID] else { return nil }
        entry.lastAccessedAt = Date()
        pendingToolTurns[sessionID] = entry
        return entry
    }

    private func storePending(_ value: PendingToolTurn, sessionID: String) {
        var v = value
        v.lastAccessedAt = Date()
        pendingToolTurns[sessionID] = v
        evictStalePending()
    }

    private func removePending(sessionID: String) {
        pendingToolTurns.removeValue(forKey: sessionID)
    }

    /// Internal access for tests and forced cleanup. DP-004-P4 Option C.
    internal func evictStalePending(now: Date = Date()) {
        let ttl = TimeInterval(configuration.pendingToolTurnTTLSeconds)
        pendingToolTurns = pendingToolTurns.filter { _, entry in
            now.timeIntervalSince(entry.lastAccessedAt) < ttl
        }
    }

    /// Exposes the count for DoctorSnapshot (used by Task 5).
    public func pendingToolTurnsCount() -> Int {
        evictStalePending()
        return pendingToolTurns.count
    }

    /// Test-only helper: safely casts and returns the sessionLoader if it is of type T.
    /// Marked nonisolated so tests can call it without await (reads only, no actor state).
    nonisolated func withSessionLoader<T>(as type: T.Type) -> T? {
        sessionLoader as? T
    }

    /// Test-only: exposes prepareTurn for parity testing (Task 6, endpointMatchesBridgePrepareTurnInitialPayload).
    /// Returns only the `.turn` case; `.rejection` is not reachable in these tests since
    /// prepareTurn only rejects via the continuation-preflight path which requires tool_result content.
    internal func prepareTurnForTesting(
        request: AnthropicMessagesRequest,
        sessionID: String,
        sessionHeader: String?
    ) async throws -> PreparedTurn {
        switch try await prepareTurn(request: request, sessionID: sessionID, sessionHeader: sessionHeader) {
        case .turn(let turn): return turn
        case .rejection: fatalError("prepareTurnForTesting: unexpected .rejection")
        }
    }

    /// Test-only: exposes convertTools for test helper use without protocol overhead.
    /// Nonisolated because it is pure computation with no mutable state dependency.
    nonisolated internal func convertToolsPublic(_ tools: [JSONObject]) throws -> [JSONObject] {
        try convertTools(tools).convertedTools
    }
}

// MARK: - BridgeDoctorStatus

public struct BridgeDoctorStatus: Sendable {
    public let authState: SubscriptionAuthState
    public let chatGPTAuthenticated: Bool
    public let accountIDSuffix: String?
    public let authError: String?
    public let lastRefresh: Date?
    public let hasRefreshToken: Bool
    public let accessTokenPreview: String?
}

/// Result type returned by the count_tokens endpoint.
public struct CountTokensResult: Codable, Sendable {
    public let input_tokens: Int

    public init(input_tokens: Int) {
        self.input_tokens = input_tokens
    }
}
