import Foundation
import CryptoKit
import Darwin

/// Opt-in local acceptance budget. Disabled unless an explicit limit is supplied at launch.
/// Every actual Responses transport attempt reserves one slot before networking.
actor AcceptanceInferenceGuard {
    static let shared = AcceptanceInferenceGuard(environment: ProcessInfo.processInfo.environment)
    private let environment: [String: String]
    init(environment: [String: String]) { self.environment = environment }

    func reserve(payload: JSONObject) throws {
        guard let configuration = try configuration() else { return }
        guard !configuration.observeOnly else {
            throw SIWCError.unsupported("acceptance observe-only; no inference request sent")
        }
        let limit = configuration.limit, path = configuration.path
        guard payload.string("model") == "gpt-6-luna", payload.object("reasoning")?.string("effort") == "low",
              payload["service_tier"] == nil || payload.string("service_tier") == "default" else {
            throw SIWCError.unsupported("acceptance guard permits only gpt-6-luna / low / Standard")
        }
        let url = URL(fileURLWithPath: path)
        let lock = try acquireLock(path: path)
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        var ledger: JSONObject
        var count = 0
        if FileManager.default.fileExists(atPath: path) {
            ledger = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
            guard case .number(let savedLimit)? = ledger["limit"], savedLimit == Double(limit),
                  case .number(let savedCount)? = ledger["count"], savedCount >= 0, savedCount <= Double(limit),
                  savedCount.rounded() == savedCount else { throw SIWCError.unsupported("invalid acceptance request ledger") }
            guard let integer = Int(exactly: savedCount) else { throw SIWCError.unsupported("invalid acceptance request ledger") }
            count = integer
        } else { ledger = JSONObject.from(["limit": .number(Double(limit)), "count": .number(0), "requests": .array([])]) }
        guard count < limit else { throw SIWCError.unsupported("acceptance inference request limit reached (\(limit)); no upstream request sent") }
        ledger["count"] = .number(Double(count + 1))
        var requests = ledger.array("requests") ?? []
        requests.append(.object(JSONObject.from(["sequence": .number(Double(count + 1)), "model": .string("gpt-6-luna"), "effort": .string("low"), "service_tier": .string("default"), "sent_at": .number(Date().timeIntervalSince1970)])))
        ledger["requests"] = .array(requests)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    func observeIngress(_ input: AnthropicMessagesRequest, headers: [String: String]) throws {
        guard let configuration = try configuration() else { return }
        let path = configuration.path
        let controls = input.messages.compactMap { message -> JSONValue? in
            guard let config = message.output_config else { return nil }
            return .object(JSONObject.from(["role": .string(["system", "user", "assistant"].contains(message.role) ? message.role : "unknown"), "empty_content": .bool(message.content.isEmpty), "output_config": .object(Self.project(config, allowed: ["effort": EffortPolicy.levels + ["auto"]]))]))
        }
        let history = input.messages.map { message in
            JSONObject.from(["role": .string(["system", "user", "assistant"].contains(message.role) ? message.role : "unknown"), "content": .array(message.content.map { block in
                .object(JSONObject.from(["type": .string(["text", "tool_use", "tool_result", "thinking", "redacted_thinking", "image", "document", "tool_addition", "tool_removal"].contains(block.string("type") ?? "") ? block.string("type")! : "unknown"), "keys": .array(block.values.keys.filter { ["type", "text", "id", "name", "input", "tool_use_id", "content", "is_error", "cache_control", "source", "thinking", "signature", "data", "tool"].contains($0) }.sorted().map(JSONValue.string)), "type_hash": .string(Self.digest(block.string("type") ?? "")), "cache_control": block.object("cache_control").map { .object(Self.project($0, allowed: ["type": ["ephemeral"], "ttl": ["5m", "1h"], "scope": ["global"]])) } ?? .null]))
            })])
        }
        let prefixes = input.messages.indices.filter { input.messages[$0].role == "assistant" }.map { index in
            JSONObject.from(["index": .number(Double(index)), "fingerprint": .string(SIWCBridge.fingerprint(Array(input.messages[...index]))), "raw_fingerprint": .string(SIWCBridge.legacyFingerprint(Array(input.messages[...index])))])
        }
        let session = headers["x-claude-code-session-id"] ?? SIWCBridge.sessionFromMetadata(input.metadata) ?? ""
        let sessionHash = Data(SHA256.hash(data: Data(session.utf8))).map { String(format: "%02x", $0) }.joined()
        func shape(_ tool: JSONObject, origin: String) -> JSONValue {
            .object(JSONObject.from(["origin": .string(origin), "name_hash": .string(Self.digest(tool.string("name") ?? "")),
                "type": .string(["function", "advisor_20260301", "tool_reference"].contains(tool.string("type") ?? "function") ? (tool.string("type") ?? "function") : "unknown"),
                "keys": .array(tool.values.keys.filter { ["type", "name", "description", "input_schema", "parameters", "model", "defer_loading", "cache_control", "strict", "allowed_callers"].contains($0) }.sorted().map(JSONValue.string)),
                "has_input_schema": .bool(tool.object("input_schema") != nil), "has_parameters": .bool(tool.object("parameters") != nil),
                "unknown_key_count": .number(Double(tool.values.keys.filter { !["type", "name", "description", "input_schema", "parameters", "model", "defer_loading", "cache_control", "strict", "allowed_callers"].contains($0) }.count))]))
        }
        var toolShapes = (input.tools ?? []).enumerated().map { shape($0.element, origin: "tools[\($0.offset)]") }
        for (index, message) in input.messages.enumerated() where message.role == "system" {
            for (blockIndex, block) in message.content.enumerated() {
                if let definition = block.object("tool")?.object("definition") {
                    toolShapes.append(shape(definition, origin: "messages[\(index)].content[\(blockIndex)].tool.definition"))
                }
            }
        }
        let record = JSONObject.from(["tool_shapes": .array(toolShapes), "session_hash": .string(sessionHash), "history": .array(history.map(JSONValue.object)), "prefixes": .array(prefixes.map(JSONValue.object)), "model_hash": .string(Self.digest(input.model)), "beta_hash": .string(Self.digest(headers["anthropic-beta"] ?? "")), "client_version_hash": .string(Self.digest(headers["x-app-version"] ?? "")), "controls": .array(controls), "output_config": input.output_config.map { .object(Self.project($0, allowed: ["effort": EffortPolicy.levels + ["auto"]])) } ?? .null, "known_betas": .array((headers["anthropic-beta"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { [EffortPolicy.messageBeta, EffortPolicy.claudeCodeMessageBeta, EffortPolicy.systemMessageBeta, EffortPolicy.toolChangesBeta].contains($0) }.map(JSONValue.string)), "thinking": input.thinking.map { .object(Self.project($0, allowed: ["type": ["adaptive", "enabled", "disabled"], "display": ["updates", "omitted"]])) } ?? .null])
        let lock = try acquireLock(path: path)
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        let url = URL(fileURLWithPath: path + ".ingress.jsonl")
        var bytes = (try? Data(contentsOf: url)) ?? Data()
        bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if configuration.observeOnly { throw SIWCError.unsupported("acceptance observe-only; no inference request sent") }
    }

    func observeReplay(_ messages: [AnthropicMessage], scope: String, stage: String, cacheHit: Bool) throws {
        guard let configuration = try configuration() else { return }
        let digests = messages.enumerated().map { index, message in
            JSONObject.from(["index": .number(Double(index)), "role": .string(["system", "user", "assistant"].contains(message.role) ? message.role : "unknown"),
                "raw_hash": .string(SIWCBridge.legacyFingerprint([message])), "canonical_hash": .string(SIWCBridge.fingerprint([message])),
                "output_config": message.output_config.map { .object(Self.project($0, allowed: ["effort": EffortPolicy.levels + ["auto"]])) } ?? .null])
        }
        let record = JSONObject.from(["stage": .string(["save", "load"].contains(stage) ? stage : "unknown"), "scope_hash": .string(Self.digest(scope)),
            "raw_prefix_hash": .string(SIWCBridge.legacyFingerprint(messages)), "canonical_prefix_hash": .string(SIWCBridge.fingerprint(messages)),
            "messages": .array(digests.map(JSONValue.object)), "cache_hit": .bool(cacheHit)])
        let lock = try acquireLock(path: configuration.path)
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        let url = URL(fileURLWithPath: configuration.path + ".replay.jsonl")
        var bytes = (try? Data(contentsOf: url)) ?? Data()
        bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func configuration() throws -> (limit: Int, path: String, observeOnly: Bool)? {
        let keys = ["CC_ROUTER_ACCEPTANCE_LIMIT", "CC_ROUTER_ACCEPTANCE_LEDGER", "CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY"]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        guard let raw = environment[keys[0]], let limit = Int(raw), limit > 0,
              let path = environment[keys[1]], path.hasPrefix("/tmp/"),
              URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix("/tmp/"),
              environment[keys[2]] == nil || ["0", "1"].contains(environment[keys[2]]!) else {
            throw SIWCError.unsupported("incomplete or invalid acceptance configuration; no inference request sent")
        }
        return (limit, path, environment[keys[2]] == "1")
    }
    private func acquireLock(path: String) throws -> Int32 {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SIWCError.storage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 == 0 else { _ = close(descriptor); throw SIWCError.storage }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { _ = close(descriptor); throw SIWCError.storage }
        }
        return descriptor
    }
    private static func project(_ object: JSONObject, allowed: [String: [String]]) -> JSONObject {
        var result = JSONObject()
        for (key, values) in allowed {
            if let value = object.string(key), values.contains(value) { result[key] = .string(value) }
        }
        result["unknown_key_count"] = .number(Double(object.values.keys.filter { allowed[$0] == nil }.count))
        return result
    }
    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}
