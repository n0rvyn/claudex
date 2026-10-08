import Foundation
import CryptoKit

/// Opt-in local acceptance budget. Disabled unless an explicit limit is supplied at launch.
/// Every actual Responses transport attempt reserves one slot before networking.
actor AcceptanceInferenceGuard {
    static let shared = AcceptanceInferenceGuard(environment: ProcessInfo.processInfo.environment)
    private let environment: [String: String]
    init(environment: [String: String]) { self.environment = environment }

    func reserve(payload: JSONObject) throws {
        guard let rawLimit = environment["CC_ROUTER_ACCEPTANCE_LIMIT"] else { return }
        guard let limit = Int(rawLimit), limit > 0,
              let path = environment["CC_ROUTER_ACCEPTANCE_LEDGER"], path.hasPrefix("/tmp/") else {
            throw SIWCError.unsupported("acceptance request guard requires a positive limit and temporary ledger")
        }
        guard payload.string("model") == "gpt-6-luna", payload.object("reasoning")?.string("effort") == "low",
              payload["service_tier"] == nil || payload.string("service_tier") == "default" else {
            throw SIWCError.unsupported("acceptance guard permits only gpt-6-luna / low / Standard")
        }
        let url = URL(fileURLWithPath: path)
        var ledger: JSONObject
        var count = 0
        if FileManager.default.fileExists(atPath: path) {
            ledger = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
            guard case .number(let savedLimit)? = ledger["limit"], savedLimit == Double(limit),
                  case .number(let savedCount)? = ledger["count"], savedCount >= 0, savedCount <= Double(limit),
                  savedCount.rounded() == savedCount else { throw SIWCError.unsupported("invalid acceptance request ledger") }
            count = Int(savedCount)
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
        guard environment["CC_ROUTER_ACCEPTANCE_LIMIT"] != nil,
              let path = environment["CC_ROUTER_ACCEPTANCE_LEDGER"], path.hasPrefix("/tmp/") else { return }
        let controls = input.messages.compactMap { message -> JSONValue? in
            guard let config = message.output_config else { return nil }
            return .object(JSONObject.from(["role": .string(message.role), "empty_content": .bool(message.content.isEmpty), "output_config": .object(config)]))
        }
        let history = input.messages.map { message in
            JSONObject.from(["role": .string(message.role), "content": .array(message.content.map { block in
                .object(JSONObject.from(["type": .string(block.string("type") ?? ""), "keys": .array(block.values.keys.sorted().map(JSONValue.string)), "cache_control": block["cache_control"] ?? .null]))
            })])
        }
        let prefixes = input.messages.indices.filter { input.messages[$0].role == "assistant" }.map { index in
            JSONObject.from(["index": .number(Double(index)), "fingerprint": .string(SIWCBridge.fingerprint(Array(input.messages[...index])))])
        }
        let session = headers["x-claude-code-session-id"] ?? SIWCBridge.sessionFromMetadata(input.metadata) ?? ""
        let sessionHash = Data(SHA256.hash(data: Data(session.utf8))).map { String(format: "%02x", $0) }.joined()
        let record = JSONObject.from(["session_hash": .string(sessionHash), "history": .array(history.map(JSONValue.object)), "prefixes": .array(prefixes.map(JSONValue.object)), "model": .string(input.model), "anthropic_beta": .string(headers["anthropic-beta"] ?? ""), "client_version": .string(headers["x-app-version"] ?? ""), "controls": .array(controls), "output_config": input.output_config.map(JSONValue.object) ?? .null, "thinking": input.thinking.map(JSONValue.object) ?? .null])
        let url = URL(fileURLWithPath: path + ".ingress.jsonl")
        var bytes = (try? Data(contentsOf: url)) ?? Data()
        bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if environment["CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY"] == "1" { throw SIWCError.unsupported("acceptance observe-only; no inference request sent") }
    }

}
