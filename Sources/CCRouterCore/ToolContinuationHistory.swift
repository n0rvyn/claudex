import Foundation

struct ToolContinuationHistory {

    struct ContinuationSlice: Sendable, Equatable {
        let replayIR: [IRBlock]
        let toolResultIR: [IRBlock]
        let continuationMessages: [IRMessage]
        let callIDs: [String]
        let toolResultIDs: [String]
    }

    enum PendingRelation: Sendable, Equatable {
        case matchesActiveTail
        case resolvedInHistory
        case absentFromTail
    }

    struct Analysis: Sendable, Equatable {
        let activeContinuation: ContinuationSlice?
        let trailingToolResultIDs: [String]
        let containsAnyToolResultHistory: Bool
        let historyShowsResolvedTurns: Bool
        private let resolvedToolUseIDs: Set<String>

        init(
            activeContinuation: ContinuationSlice?,
            trailingToolResultIDs: [String],
            containsAnyToolResultHistory: Bool,
            historyShowsResolvedTurns: Bool,
            resolvedToolUseIDs: Set<String>
        ) {
            self.activeContinuation = activeContinuation
            self.trailingToolResultIDs = trailingToolResultIDs
            self.containsAnyToolResultHistory = containsAnyToolResultHistory
            self.historyShowsResolvedTurns = historyShowsResolvedTurns
            self.resolvedToolUseIDs = resolvedToolUseIDs
        }

        func relation(toCachedCallIDs cachedCallIDs: [String]) -> PendingRelation {
            let cachedSet = Set(cachedCallIDs)
            if let activeContinuation, Set(activeContinuation.callIDs) == cachedSet {
                return .matchesActiveTail
            }
            if !cachedSet.isEmpty, cachedSet.isSubset(of: resolvedToolUseIDs) {
                return .resolvedInHistory
            }
            return .absentFromTail
        }
    }

    static func analyze(_ requestIR: [IRMessage]) -> Analysis {
        let containsAnyToolResultHistory = requestIR.contains { message in
            message.content.contains { block in
                if case .toolResult = block { return true }
                return false
            }
        }

        let tail = trailingUserContinuationTail(in: requestIR)
        let activeContinuation = activeContinuation(in: requestIR, tail: tail)
        let resolvedToolUseIDs = resolvedToolUseIDs(in: requestIR)
        let activeToolResultIDs = Set(activeContinuation?.toolResultIDs ?? [])
        let historyShowsResolvedTurns = !resolvedToolUseIDs.subtracting(activeToolResultIDs).isEmpty

        return Analysis(
            activeContinuation: activeContinuation,
            trailingToolResultIDs: tail.ids,
            containsAnyToolResultHistory: containsAnyToolResultHistory,
            historyShowsResolvedTurns: historyShowsResolvedTurns,
            resolvedToolUseIDs: resolvedToolUseIDs
        )
    }

    private static func trailingUserContinuationTail(in requestIR: [IRMessage]) -> (messages: [IRMessage], toolResults: [IRBlock], ids: [String]) {
        guard !requestIR.isEmpty else { return ([], [], []) }

        var reversedMessages: [IRMessage] = []
        var reversedToolResults: [IRBlock] = []
        var reversedIDs: [String] = []
        var index = requestIR.count - 1

        while index >= 0 {
            let message = requestIR[index]
            guard message.role == "user" else { break }

            reversedMessages.append(message)

            let toolResults = message.content.compactMap { block -> IRBlock? in
                guard case .toolResult = block else { return nil }
                return block
            }
            let ids = toolResults.compactMap { block -> String? in
                guard case .toolResult(let toolUseID, _) = block else { return nil }
                return toolUseID
            }

            reversedToolResults.append(contentsOf: toolResults.reversed())
            reversedIDs.append(contentsOf: ids.reversed())
            index -= 1
        }

        guard !reversedIDs.isEmpty else { return ([], [], []) }
        return (reversedMessages.reversed(), reversedToolResults.reversed(), reversedIDs.reversed())
    }

    private static func activeContinuation(
        in requestIR: [IRMessage],
        tail: (messages: [IRMessage], toolResults: [IRBlock], ids: [String])
    ) -> ContinuationSlice? {
        guard !tail.ids.isEmpty else { return nil }

        let tailCount = tail.messages.count
        guard requestIR.count > tailCount else { return nil }

        let index = requestIR.count - tailCount - 1
        guard index >= 0 else { return nil }
        let assistantMessage = requestIR[index]
        guard assistantMessage.role == "assistant" else { return nil }

        let replayIR = assistantMessage.content.filter { block in
            switch block {
            case .thinking, .toolUse:
                return true
            default:
                return false
            }
        }
        let callIDs = replayIR.compactMap { block -> String? in
            guard case .toolUse(let id, _, _) = block else { return nil }
            return id
        }

        guard !callIDs.isEmpty else { return nil }
        guard Set(tail.ids).isSubset(of: Set(callIDs)) else { return nil }

        return ContinuationSlice(
            replayIR: replayIR,
            toolResultIR: tail.toolResults,
            continuationMessages: tail.messages,
            callIDs: callIDs,
            toolResultIDs: tail.ids
        )
    }

    private static func resolvedToolUseIDs(in requestIR: [IRMessage]) -> Set<String> {
        var seenToolUses = Set<String>()
        var resolved = Set<String>()

        for message in requestIR {
            switch message.role {
            case "assistant":
                for block in message.content {
                    guard case .toolUse(let id, _, _) = block else { continue }
                    seenToolUses.insert(id)
                }
            case "user":
                for block in message.content {
                    guard case .toolResult(let toolUseID, _) = block else { continue }
                    if seenToolUses.contains(toolUseID) {
                        resolved.insert(toolUseID)
                    }
                }
            default:
                continue
            }
        }

        return resolved
    }
}
