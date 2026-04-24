import Foundation
import CryptoKit
@testable import CCRouterCore
import Testing

struct PromptCacheKeyStabilityTests {
    @Test
    func returnsSessionIDLowercasedWhenPresent() {
        let key = PromptCacheKey.stable(
            sessionID: "ABC-123",
            instructions: "irrelevant",
            firstUserMessageText: "irrelevant"
        )
        #expect(key == "abc-123")
    }

    @Test
    func sameSessionProducesSameKey() {
        let a = PromptCacheKey.stable(sessionID: "s1", instructions: "x", firstUserMessageText: "y")
        let b = PromptCacheKey.stable(sessionID: "s1", instructions: "different", firstUserMessageText: "different")
        #expect(a == b)
    }

    @Test
    func fallbackHashingIsDeterministic() {
        let a = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
        let b = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
        #expect(a == b)
        #expect(a.count == 64)
    }

    @Test
    func fallbackDifferentInputsProduceDifferentKeys() {
        let a = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
        let b = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "world")
        #expect(a != b)
    }

    @Test
    func separatorPreventsShiftCollision() {
        // "ab" + sep + "cd"  must differ from "a" + sep + "bcd"
        let a = PromptCacheKey.stable(sessionID: nil, instructions: "ab", firstUserMessageText: "cd")
        let b = PromptCacheKey.stable(sessionID: nil, instructions: "a", firstUserMessageText: "bcd")
        #expect(a != b)
    }

    @Test
    func emptySessionFallsBack() {
        let a = PromptCacheKey.stable(sessionID: "", instructions: "sys", firstUserMessageText: "hi")
        #expect(a.count == 64)
    }

    @Test
    func oversizedSessionFallsBack() {
        let big = String(repeating: "a", count: 1024)
        let a = PromptCacheKey.stable(sessionID: big, instructions: "sys", firstUserMessageText: "hi")
        #expect(a.count == 64)
    }
}
