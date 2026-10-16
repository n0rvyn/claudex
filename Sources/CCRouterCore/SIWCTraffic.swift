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
        await logger.log(event, permissions: 0o600)
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
    func callFailure(id: UUID, role: String, fields: JSONObject) async {
        var event = fields
        event["stage"] = .string("model_failure")
        event["event"] = .string("model_failure")
        event["id"] = .string(id.uuidString)
        event["role"] = .string(role)
        if let diagnosticID = ClassifierDiagnostics.requestID { event["diagnostic_id"] = .string(diagnosticID) }
        await log(event)
        await ClassifierDiagnostics.log(event)
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
    private var cachedEvents: [(time: Double, event: JSONObject)] = []
    private var historicalStart: Date?
    private var previousWindowStart: Double?
    private let ledgerDecoder = JSONDecoder()

    private func decodeLedgerLine(_ line: String) -> (time: Double, event: JSONObject)? {
        guard let data = line.data(using: .utf8), let event = try? ledgerDecoder.decode(JSONObject.self, from: data),
              case .number(let time)? = event["logged_at_unix_ms"] else { return nil }
        return (time, event)
    }

    private var snapshotBusy = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private func acquireSnapshot() async {
        if snapshotBusy { await withCheckedContinuation { snapshotWaiters.append($0) } }
        else { snapshotBusy = true }
    }
    private func releaseSnapshot() {
        if snapshotWaiters.isEmpty { snapshotBusy = false }
        else { snapshotWaiters.removeFirst().resume() }
    }

    func snapshot(now: Date = Date()) async -> SIWCTrafficSnapshot {
        await acquireSnapshot()
        defer { releaseSnapshot() }
        let end = now.timeIntervalSince1970 * 1000, start = end - 300_000
        // Preserve arbitrary test/clock rollback semantics after expired entries were evicted.
        let update = await logger.ledgerUpdate(forceReset: previousWindowStart.map { start < $0 } ?? false)
        if update.reset { cachedEvents.removeAll(keepingCapacity: true); historicalStart = nil }
        guard update.validUTF8 else {
            var empty = SIWCTrafficSnapshot(); empty.startedAt = startedAt
            return empty
        }
        for line in update.completeLines {
            guard let entry = decodeLedgerLine(line) else { continue }
            let date = Date(timeIntervalSince1970: entry.time / 1000)
            historicalStart = min(historicalStart ?? startedAt, date)
            if entry.time > start { cachedEvents.append(entry) }
        }
        cachedEvents.removeAll { $0.time <= start }
        previousWindowStart = start
        // A valid last line without newline counts, but is provisional: appended
        // bytes may change it. Never commit it until its newline arrives.
        let trailing = update.trailingLine.flatMap { decodeLedgerLine($0) }
        var events = cachedEvents
        if let trailing { events.append(trailing) }
        var result = SIWCTrafficSnapshot(); result.startedAt = startedAt
        result.startedAt = min(startedAt, historicalStart ?? startedAt)
        var finished: Set<String> = []
        var latencies: [Int] = []
        for (time, event) in events {
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
        catch {
            await traffic.callFailure(id: id, role: role, fields: ClassifierDiagnostics.failureFields(error))
            await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true)
            throw error
        }
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
                            await traffic.callFailure(id: id, role: role, fields: ClassifierDiagnostics.failureFields(event))
                            await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true)
                        }
                        continuation.yield(event)
                    }
                    if !terminal {
                        await traffic.callFailure(id: id, role: role, fields: ClassifierDiagnostics.failureFields(SIWCError.remote("interrupted_stream")))
                        await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true)
                    }
                    continuation.finish()
                } catch {
                    if !terminal {
                        await traffic.callFailure(id: id, role: role, fields: ClassifierDiagnostics.failureFields(error))
                        await traffic.callFinished(id: id, role: role, started: started, usage: nil, failed: true)
                    }
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
