import Foundation
@testable import CCRouterCore
import Testing

struct ToolContinuationHistoryTests {

    @Test
    func oldResolvedRoundPlusCurrentContinuationReturnsOnlyActiveTail() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "user", content: [.text("old request")]),
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_old", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_old", content: [.text("old success")]),
            ]),
            IRMessage(role: "assistant", content: [
                .thinking(encryptedContent: Data("sig".utf8), summary: "need tool"),
                .toolUse(id: "toolu_current", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_current", content: [.text("current success")]),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.trailingToolResultIDs == ["toolu_current"])
        #expect(analysis.historyShowsResolvedTurns)
        #expect(analysis.activeContinuation?.callIDs == ["toolu_current"])
        #expect(analysis.activeContinuation?.toolResultIDs == ["toolu_current"])
    }

    @Test
    func multipleCurrentToolResultsStayInOrder() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_1", name: "Bash", input: JSONObject()),
                .toolUse(id: "toolu_2", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_1", content: [.text("first")]),
                .toolResult(toolUseID: "toolu_2", content: [.text("second")]),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.activeContinuation?.toolResultIDs == ["toolu_1", "toolu_2"])
        #expect(analysis.activeContinuation?.callIDs == ["toolu_1", "toolu_2"])
        #expect(analysis.activeContinuation?.toolResultIR == [
            .toolResult(toolUseID: "toolu_1", content: [.text("first")]),
            .toolResult(toolUseID: "toolu_2", content: [.text("second")]),
        ])
    }

    @Test
    func continuationKeepsSkillBodyTextAfterToolResultInSameUserMessage() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_skill", name: "Skill", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_skill", content: [.text("Launching skill: domain-intel:scan")]),
                .text("Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.activeContinuation?.toolResultIDs == ["toolu_skill"])
        #expect(analysis.activeContinuation?.continuationMessages == [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_skill", content: [.text("Launching skill: domain-intel:scan")]),
                .text("Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"),
            ]),
        ])
    }

    @Test
    func continuationKeepsSkillBodyTextInFollowingUserMessage() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_skill", name: "Skill", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_skill", content: [.text("Launching skill: domain-intel:scan")]),
            ]),
            IRMessage(role: "user", content: [
                .text("Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.activeContinuation?.toolResultIDs == ["toolu_skill"])
        #expect(analysis.activeContinuation?.continuationMessages == [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_skill", content: [.text("Launching skill: domain-intel:scan")]),
            ]),
            IRMessage(role: "user", content: [
                .text("Base directory for this skill: /skills/scan\n\n## Process\nBash(command=\"pwd\")"),
            ]),
        ])
    }

    @Test
    func orphanedTrailingToolResultReturnsNoActiveContinuation() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [.text("no tools here")]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_orphaned", content: [.text("oops")]),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.trailingToolResultIDs == ["toolu_orphaned"])
        #expect(analysis.activeContinuation == nil)
    }

    @Test
    func resolvedPriorRoundFollowedByFreshUserTextReturnsNoActiveContinuation() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_done", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_done", content: [.text("done")]),
            ]),
            IRMessage(role: "assistant", content: [.text("completed")]),
            IRMessage(role: "user", content: [.text("fresh turn")]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.containsAnyToolResultHistory)
        #expect(analysis.historyShowsResolvedTurns)
        #expect(analysis.trailingToolResultIDs.isEmpty)
        #expect(analysis.activeContinuation == nil)
    }

    @Test
    func cachedPendingRelationDistinguishesMatchResolvedAndAbsent() {
        let requestIR: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_done", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_done", content: [.text("done")]),
            ]),
            IRMessage(role: "assistant", content: [
                .toolUse(id: "toolu_active", name: "Bash", input: JSONObject()),
            ]),
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "toolu_active", content: [.text("active")]),
            ]),
        ]

        let analysis = ToolContinuationHistory.analyze(requestIR)

        #expect(analysis.relation(toCachedCallIDs: ["toolu_active"]) == .matchesActiveTail)
        #expect(analysis.relation(toCachedCallIDs: ["toolu_done"]) == .resolvedInHistory)
        #expect(analysis.relation(toCachedCallIDs: ["toolu_missing"]) == .absentFromTail)
    }
}
