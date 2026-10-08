import Foundation

/// Only fixed categories, generated IDs and field-presence flags leave this boundary.
/// Never emits request/response text, header values, tool inputs or error descriptions.
enum ClassifierDiagnostics {
    @TaskLocal static var requestID: String?

    static func log(_ fields: JSONObject) async {
        guard let requestID else { return }
        var event = fields
        event["stage"] = .string("classifier_diagnostic")
        event["diagnostic_id"] = .string(requestID)
        await TraceLogger.shared.log(event)
    }

    static func category(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is ResponsesHTTPError { return "upstream_http" }
        if error is DecodingError { return "decode" }
        if error is URLError { return "transport" }
        if let error = error as? SIWCError {
            switch error {
            case .signInRequired, .permissionRequired, .invalidIdentity: return "authentication"
            case .storage: return "storage"
            case .unsupported(let reason):
                if reason.contains("session identifier") { return "missing_session" }
                if reason.contains("disabled thinking") { return "unsupported_thinking" }
                if reason.contains("replay") { return "replay" }
                return "unsupported_capability"
            case .remote: return "remote_or_stream"
            default: return "authentication_flow"
            }
        }
        return "bridge_or_stream"
    }

    static func endpoint(_ path: String) -> String {
        // Unknown paths can contain credentials or user-controlled identifiers.
        let path = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        switch path {
        case "/", "/health", "/healthz", "/v1/messages", "/v1/messages/count_tokens",
             "/v1/messages/classify", "/v1/tool_permission", "/v1/responses": return path
        default: return "other_endpoint"
        }
    }

    static func reviewPresence(_ object: [String: Any]) -> Bool {
        object.keys.contains { key in
            let key = key.lowercased()
            return key.contains("classifier") || key.contains("safeguard") || key.contains("review")
        }
    }

    static func ingress(_ request: HTTPRequest) -> JSONObject {
        let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let output = object["output_config"] as? [String: Any] ?? [:]
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let model = object["model"] as? String ?? ""
        let knownModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5"]
        return JSONObject.from([
            "event": .string("ingress"), "endpoint": .string(endpoint(request.path)),
            "method": .string(["GET", "HEAD", "POST"].contains(request.method) ? request.method : "other"),
            "client_model": .string(knownModels.contains(model) ? model : "other_model"),
            "review_field_present": .bool(reviewPresence(object) || reviewPresence(metadata)),
            "review_header_present": .bool(reviewPresence(request.headers)),
            "session_header_present": .bool(request.headers["x-claude-code-session-id"] != nil),
            "thinking_present": .bool(object["thinking"] != nil),
            "output_format_present": .bool(output["format"] != nil),
            "stream_requested": .bool(object["stream"] as? Bool ?? false)
        ])
    }

    static func resolved(_ route: ModelRoute) async {
        let known = route.upstreamModel.hasPrefix("gpt-") || route.upstreamModel.hasPrefix("codex-")
        let safe = route.upstreamModel.range(of: "^[a-z0-9._-]{1,80}$", options: .regularExpression) != nil
        await log(JSONObject.from(["event": .string("resolved_route"),
            "upstream_model": .string(known && safe ? route.upstreamModel : "other_model"),
            "effort": .string(EffortPolicy.levels.contains(route.reasoningEffort) ? route.reasoningEffort : "other_effort")]))
    }

    static func responseFields(_ response: HTTPResponse) -> JSONObject {
        var result = JSONObject.from(["event": .string("gateway_response"), "status": .number(Double(response.statusCode)),
            "review_header_present": .bool(reviewPresence(response.headers))])
        if let data = response.bodyData,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            result["review_field_present"] = .bool(reviewPresence(object))
            let error = object["error"] as? [String: Any] ?? [:]
            let type = error["type"] as? String ?? ""
            let allowed = ["invalid_request_error", "authentication_error", "permission_error", "rate_limit_error", "api_error", "overloaded_error"]
            if response.statusCode >= 400 { result["error_category"] = .string(allowed.contains(type) ? type : "other_error") }
        }
        return result
    }

    static func observe(_ request: HTTPRequest, handler: () async -> HTTPResponse) async -> HTTPResponse {
        let id = UUID().uuidString
        return await $requestID.withValue(id) {
            await log(ingress(request))
            let response = await handler()
            await log(responseFields(response))
            guard case .stream(let producer) = response.body else { return response }
            return HTTPResponse(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase,
                headers: response.headers, release: response.release, stream: { writer in
                    try await $requestID.withValue(id) {
                        let observer = DiagnosticBodyWriter(base: writer)
                        do {
                            try await producer(observer)
                            await log(JSONObject.from(["event": .string("stream_finished"),
                                "message_stop_seen": .bool(await observer.messageStopSeen)]))
                        } catch {
                            await log(JSONObject.from(["event": .string("stream_failed"), "error_category": .string(category(error))]))
                            throw error
                        }
                    }
                })
        }
    }
}

private actor DiagnosticBodyWriter: HTTPBodyWriter {
    let base: any HTTPBodyWriter
    var messageStopSeen = false
    init(base: any HTTPBodyWriter) { self.base = base }
    func write(_ chunk: Data) async throws {
        // Inspect a frame only for fixed metadata, never retain or log its body.
        if let frame = String(data: chunk, encoding: .utf8) {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") {
                let data = Data(line.dropFirst(6).utf8)
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let message = object["message"] as? [String: Any] ?? [:]
                if object["type"] as? String == "message_stop" { messageStopSeen = true }
                if ClassifierDiagnostics.reviewPresence(object) || ClassifierDiagnostics.reviewPresence(message) {
                    await ClassifierDiagnostics.log(JSONObject.from(["event": .string("stream_review_fields"), "review_field_present": .bool(true)]))
                }
            }
        }
        try await base.write(chunk)
    }
    func finish() async throws { try await base.finish() }
}
