import Foundation

/// Ordinal policy, not a conversion between reasoning-token budgets or model compute.
public enum EffortPolicy {
    public static let levels = ["low", "medium", "high", "xhigh", "max"]
    public static let messageBeta = "mid-conversation-output-config-2026-07-01"
    /// Observed on installed Claude Code 2.1.292; same effort-only control wire shape.
    public static let claudeCodeMessageBeta = "per-turn-control-2026-07-01"

    public static let systemMessageBeta = "mid-conversation-system-2026-04-07"
    public static let toolChangesBeta = "mid-conversation-tool-changes-2026-07-01"

    /// A public output-config control message takes effect at the next user message and remains active.
    public static func clientEffort(_ input: AnthropicMessagesRequest, headers: [String: String]) throws -> String? {
        let betas = (headers["anthropic-beta"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let native = betas.contains(claudeCodeMessageBeta)
        var active: JSONObject? = input.output_config
        var pending: JSONObject?
        for message in input.messages {
            if let control = message.output_config {
                guard message.role == "system",
                      Set(control.values.keys) == Set(["effort"]), control.string("effort") != nil else {
                    throw SIWCError.unsupported("effort control requires a system message containing only output_config.effort")
                }
                guard message.content.isEmpty || (native && betas.contains(systemMessageBeta)) else {
                    throw SIWCError.unsupported("nonempty effort control requires the native per-turn and mid-conversation system betas")
                }
                if !message.content.isEmpty { try SIWCBridge.validateSystemContent(message.content) }
                guard betas.contains(messageBeta) || betas.contains(claudeCodeMessageBeta) else {
                    throw SIWCError.unsupported("per-message effort requires anthropic-beta: " + messageBeta)
                }
                // Installed SDK Een attaches this control immediately after its
                // user turn, including at the request tail. Public beta semantics
                // remain next-user activation.
                if native { active = control; pending = nil } else { pending = control }
            } else if message.role == "user", let next = pending { active = next; pending = nil }
        }
        guard let active, let value = active["effort"] else { return nil }
        guard let effort = value.stringValue else { throw SIWCError.unsupported("output_config.effort must be a string") }
        return effort
    }

    public static func validateAdjustment(requested: String?, thinking: JSONObject?) throws {
        if let requested, requested != "auto", !levels.contains(requested) {
            throw SIWCError.unsupported("unsupported Claude effort: " + requested)
        }
        if let thinking {
            guard thinking.string("type") == "adaptive", thinking["budget_tokens"] == nil else {
                throw SIWCError.unsupported("Allow Claude to adjust supports ordinal effort and adaptive thinking only; thinking budgets and disabled thinking cannot be translated")
            }
        }
    }

    public static func resolve(route: ModelRoute, requested: String?, thinking: JSONObject?, catalog: SIWCModelCatalogSnapshot, accountID: String) throws -> ModelRoute {
        guard catalog.accountID == accountID, catalog.isFresh(), catalog.models.allSatisfy({ $0.accountID == accountID }) else {
            throw SIWCError.unsupported("fresh model capabilities for the selected account are required; refresh models")
        }
        guard let model = catalog.models.first(where: { $0.id == route.upstreamModel }),
              let ceiling = levels.firstIndex(of: route.reasoningEffort), model.scalarReasoningEfforts.contains(route.reasoningEffort) else {
            throw SIWCError.unsupported("choose an available model and explicit supported default / maximum effort")
        }
        try validateAdjustment(requested: requested, thinking: thinking)
        let limit: Int
        if let requested, requested != "auto" {
            guard let index = levels.firstIndex(of: requested) else {
                throw SIWCError.unsupported("unsupported Claude effort: " + requested + "; choose low, medium, high, xhigh, max or auto")
            }
            limit = min(ceiling, index)
        } else { limit = ceiling }
        guard let effort = levels.prefix(limit + 1).last(where: { model.scalarReasoningEfforts.contains($0) }) else {
            throw SIWCError.unsupported("model has no supported effort at or below the requested level; upward fallback is disabled")
        }
        return ModelRoute(upstreamModel: route.upstreamModel, reasoningEffort: effort, textVerbosity: route.textVerbosity)
    }
}
