import Foundation

/// Single routing resolution result: the full set of per-request fields needed
/// to construct a `/responses` payload for one upstream call.
public struct ModelRoute: Codable, Sendable, Equatable {
    public let upstreamModel: String
    public let reasoningEffort: String
    public let textVerbosity: String

    public init(upstreamModel: String, reasoningEffort: String, textVerbosity: String) {
        self.upstreamModel = upstreamModel
        self.reasoningEffort = reasoningEffort
        self.textVerbosity = textVerbosity
    }
}

/// One matching rule: `match` is the Claude model lowercased substring to check;
/// the first rule whose match is contained in the Claude model name wins.
public struct ModelRoutingRule: Codable, Sendable, Equatable {
    public let match: String
    public let route: ModelRoute

    public init(match: String, route: ModelRoute) {
        self.match = match
        self.route = route
    }
}

/// A routing resolution result with both the route and the matched rule label.
public struct ResolvedRoute: Sendable, Equatable {
    public let route: ModelRoute
    public let matchLabel: String

    public init(route: ModelRoute, matchLabel: String) {
        self.route = route
        self.matchLabel = matchLabel
    }
}

/// Full routing table: rules are checked in order; the first match wins.
public struct ModelRoutingTable: Codable, Sendable, Equatable {
    public let rules: [ModelRoutingRule]
    public let fallback: ModelRoute

    public init(rules: [ModelRoutingRule], fallback: ModelRoute) {
        self.rules = rules
        self.fallback = fallback
    }

    /// Resolves a Claude `model` string to a `ModelRoute`.
    /// Performs a case-insensitive substring match; the first matching rule wins.
    /// Falls through to `fallback` when no rule matches.
    public func resolve(for claudeModel: String) -> ModelRoute {
        let needle = claudeModel.lowercased()
        for rule in rules {
            if needle.contains(rule.match.lowercased()) {
                return rule.route
            }
        }
        return fallback
    }

    /// Resolves a Claude `model` string to a `ResolvedRoute`, including the matched rule label.
    /// Falls through to `fallback` with matchLabel `"fallback"` when no rule matches.
    public func resolveWithMatch(for claudeModel: String) -> ResolvedRoute {
        let needle = claudeModel.lowercased()
        for rule in rules {
            if needle.contains(rule.match.lowercased()) {
                return ResolvedRoute(route: rule.route, matchLabel: rule.match)
            }
        }
        return ResolvedRoute(route: fallback, matchLabel: "fallback")
    }
}

// MARK: - Default table (Phase 2 baseline)

public extension ModelRoutingTable {
    /// Three-rule baseline for fresh installs.
    /// Substring authority: `docs/scheme3/10 §7.8` whitelist + probe-confirmed ID.
    /// `gpt-5.3-codex-spark` probe returned 200 on 2026-04-22
    /// (see `docs/research/2026-04-22-upstream-model-probe.md`); per DP-002 Option B
    /// haiku is mapped to the probe-confirmed ID to deliver the user-requested routing now.
    /// Effort/verbosity: Phase 0 defaults.
    static let defaultTable = ModelRoutingTable(
        rules: [
            ModelRoutingRule(match: "opus",   route: ModelRoute(upstreamModel: "gpt-5.4",             reasoningEffort: "xhigh", textVerbosity: "low")),
            ModelRoutingRule(match: "sonnet", route: ModelRoute(upstreamModel: "gpt-5.4",             reasoningEffort: "xhigh", textVerbosity: "low")),
            ModelRoutingRule(match: "haiku",  route: ModelRoute(upstreamModel: "gpt-5.3-codex-spark", reasoningEffort: "xhigh", textVerbosity: "low")),
        ],
        fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
    )

    static let defaultAdvisorRoute = ModelRoute(
        upstreamModel: "gpt-5.4",
        reasoningEffort: "xhigh",
        textVerbosity: "low"
    )
}
