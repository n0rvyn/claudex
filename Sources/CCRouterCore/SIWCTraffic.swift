import Foundation

public struct SIWCTrafficSnapshot: Codable, Sendable {
    public var startedAt: Date = Date()
    public var requests = 0
    public var modelCalls = 0
    public var errors = 0
    public var successes = 0
    public var lastOutcome: String?
    public var p50LatencyMilliseconds: Int?
    public var p95LatencyMilliseconds: Int?
    public var inputTokens = 0
    public var outputTokens = 0
    public var advisorTokens = 0
    public var usageReported = false
    public var usageIncomplete = false
    public var lastLatencyMilliseconds: Int?
    public var lastError: String?
    public var buckets: [Int] = Array(repeating: 0, count: 5)
    public init() {}
}

/// Metadata only: no transcripts, tool arguments, account IDs or credentials.
/// Each bridge owns its recorder; tests inherit their isolated replay directory.
actor SIWCTraffic {
    let logger: TraceLogger
    let startedAt: Date
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        logger = TraceLogger(fileURL: directory.appendingPathComponent("traffic.jsonl"))
        startedAt = Date()
    }
    private func log(_ event: JSONObject) async {
        await logger.log(event)
        let path = await logger.path
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private var activeRequests: Set<UUID> = []
    func gatewayRequest(id: UUID = UUID()) async {
        activeRequests.insert(id)
        await log(JSONObject.from(["stage": .string("gateway_request")]))
    }
    func gatewayFinished(id: UUID, started: Date, failed: Bool, cancelled: Bool = false) async {
        guard activeRequests.remove(id) != nil else { return }
        await log(JSONObject.from(["stage": .string("gateway_result"), "id": .string(id.uuidString),
            "failed": .bool(failed), "cancelled": .bool(cancelled), "duration_ms": .number(Date().timeIntervalSince(started) * 1000)]))
    }
    func callStarted(id: UUID, role: String) async {
        await log(JSONObject.from(["stage": .string("model_call"), "id": .string(id.uuidString), "role": .string(role)]))
    }
    func callFinished(id: UUID, role: String, started: Date, usage: JSONObject?, failed: Bool) async {
        var event = JSONObject.from(["stage": .string("model_result"), "id": .string(id.uuidString), "role": .string(role),
            "failed": .bool(failed), "duration_ms": .number(Date().timeIntervalSince(started) * 1000)])
        // Never substitute estimated input tokens for provider-reported usage.
        if let input = usage?["input_tokens"]?.intValue, let output = usage?["output_tokens"]?.intValue {
            event["input_tokens"] = .number(Double(input)); event["output_tokens"] = .number(Double(output))
        }
        await log(event)
    }
    func snapshot(now: Date = Date()) async -> SIWCTrafficSnapshot {
        // Read the whole metadata ledger, not an arbitrary tail of mixed log stages.
        let lines = await logger.recentLines(limit: Int.max)
        var result = SIWCTrafficSnapshot(); result.startedAt = startedAt
        let end = now.timeIntervalSince1970 * 1000, start = end - 300_000
        var finished: Set<String> = []
        var latencies: [Int] = []
        for line in lines {
            guard let data = line.data(using: .utf8), let event = try? JSONDecoder().decode(JSONObject.self, from: data),
                  case .number(let time)? = event["logged_at_unix_ms"] else { continue }
            result.startedAt = min(result.startedAt, Date(timeIntervalSince1970: time / 1000))
            guard time > start, time <= end else { continue }
            switch event.string("stage") {
            case "gateway_request":
                result.requests += 1
                let index = min(4, max(0, Int((time - start) / 60_000))); result.buckets[index] += 1
            case "gateway_result":
                guard event["cancelled"] != .bool(true) else { continue }
                result.lastLatencyMilliseconds = event["duration_ms"]?.intValue
                if let latency = result.lastLatencyMilliseconds { latencies.append(latency) }
                if event["failed"] == .bool(true) {
                    result.errors += 1; result.lastError = "Gateway request failed"; result.lastOutcome = "Gateway request failed"
                } else { result.successes += 1; result.lastOutcome = "Last request completed" }
            case "model_call": result.modelCalls += 1
            case "model_result":
                guard let id = event.string("id"), finished.insert(id).inserted else { continue }

                if let input = event["input_tokens"]?.intValue, let output = event["output_tokens"]?.intValue {
                    result.usageReported = true; result.inputTokens += input; result.outputTokens += output
                    if event.string("role") == "advisor" { result.advisorTokens += input + output }
                } else { result.usageIncomplete = true }
            default: break
            }
        }
        latencies.sort()
        if !latencies.isEmpty {
            result.p50LatencyMilliseconds = latencies[Int((Double(latencies.count - 1) * 0.5).rounded())]
            result.p95LatencyMilliseconds = latencies[Int((Double(latencies.count - 1) * 0.95).rounded())]
        }
        return result
    }
}

/// Records each actual upstream call separately, including Advisor and executor resume.
/// It forwards the original stream and cancellation; no retries or altered payloads.
struct TrafficResponsesClient: ResponsesStreamingClient {
    let base: any ResponsesStreamingClient
    let traffic: SIWCTraffic
    let role: String
    func cancelRequest(_ id: UUID) async { await base.cancelRequest(id) }
    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials) async throws -> AsyncThrowingStream<JSONObject, Error> {
        try await streamEvents(request: request, credentials: credentials, requestID: UUID())
    }
    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials, requestID: UUID) async throws -> AsyncThrowingStream<JSONObject, Error> {
        let id = UUID(), started = Date()
        await traffic.callStarted(id: id, role: role)
        let stream: AsyncThrowingStream<JSONObject, Error>
        do { stream = try await base.streamEvents(request: request, credentials: credentials, requestID: requestID) }
        catch { await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true); throw error }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var terminal = false
                do {
                    for try await event in stream {
                        try Task.checkCancellation()
                        if event.string("type") == "response.completed", !terminal {
                            terminal = true
                            await traffic.callFinished(id: id, role: role, started: started, usage: event.object("response")?.object("usage"), failed: false)
                        }
                        if ["response.failed", "response.incomplete", "error"].contains(event.string("type") ?? ""), !terminal {
                            terminal = true
                            await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true)
                        }
                        continuation.yield(event)
                    }
                    if !terminal { await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true) }
                    continuation.finish()
                } catch {
                    if !terminal { await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination { task.cancel(); Task { await base.cancelRequest(requestID) } }
            }
        }
    }
    func perform(request: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] {
        var events: [JSONObject] = []
        for try await event in try await streamEvents(request: request, credentials: credentials) { events.append(event) }
        return events
    }
}
