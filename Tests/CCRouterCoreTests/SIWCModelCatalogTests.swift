import Foundation
import Testing
@testable import CCRouterCore

private actor CatalogFixture {
    var calls = 0
    var account = "account-a"
    var failure = false
    func setAccount(_ value: String) { account = value }
    func fail(_ value: Bool) { failure = value }
    func fetch() async throws -> [SIWCModelSummary] {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if failure { throw SIWCError.remote("fixture_offline") }
        return [SIWCModelSummary(id: "fixture-luna", label: "Fixture", accountID: account, details: JSONObject([
            "supported_reasoning_levels": .array([.object(JSONObject(["effort": .string("low")])), .object(JSONObject(["effort": .string("high")]))]),
            "supports_parallel_tool_calls": .bool(true)
        ]))]
    }
}
struct SIWCModelCatalogTests {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + UUID().uuidString) }
    @Test func freshCacheSurvivesControllerRecreationAndSeparatesAccounts() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = CatalogFixture()
        let first = SIWCModelCatalog(directory: dir, loader: { try await fixture.fetch() })
        let a = try await first.load(accountID: "account-a")
        let second = SIWCModelCatalog(directory: dir, loader: { try await fixture.fetch() })
        let cached = try await second.load(accountID: "account-a")
        #expect(cached.fetchedAt == a.fetchedAt)
        #expect(await fixture.calls == 1)
        await fixture.setAccount("account-b")
        let b = try await second.load(accountID: "account-b")
        #expect(b.accountID == "account-b")
        #expect(await fixture.calls == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count == 2)
    }
    @Test func expiredCacheFetchesOnceAndConcurrentRefreshCoalesces() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = CatalogFixture(), old = Date(timeIntervalSince1970: 1000)
        let first = SIWCModelCatalog(directory: dir, loader: { try await fixture.fetch() }, now: { old })
        _ = try await first.load(accountID: "account-a")
        let second = SIWCModelCatalog(directory: dir, loader: { try await fixture.fetch() }, now: { old.addingTimeInterval(3601) })
        async let a = second.load(accountID: "account-a")
        async let b = second.load(accountID: "account-a")
        let results = try await (a, b)
        #expect(results.0.fetchedAt == results.1.fetchedAt)
        #expect(await fixture.calls == 2)
        #expect(!results.0.isFresh(at: old))
    }
    @Test func failedRefreshInvalidatesDiskCacheAndWrongAccountCannotPopulateIt() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = CatalogFixture()
        let catalog = SIWCModelCatalog(directory: dir, loader: { try await fixture.fetch() })
        _ = try await catalog.load(accountID: "account-a")
        await fixture.fail(true)
        await #expect(throws: SIWCError.self) { _ = try await catalog.load(accountID: "account-a", force: true) }
        await #expect(throws: SIWCError.self) { _ = try await catalog.load(accountID: "account-a") }
        #expect(await fixture.calls == 3)
        await fixture.fail(false); await fixture.setAccount("account-b")
        await #expect(throws: SIWCError.self) { _ = try await catalog.load(accountID: "account-a") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
    @Test func routeValidationUsesMetadataAndNeverGuessesOrSelectsReplacement() async throws {
        let fixture = CatalogFixture(), models = try await fixture.fetch()
        let snapshot = SIWCModelCatalogSnapshot(accountID: "account-a", fetchedAt: Date(), models: models)
        #expect(snapshot.validationError(for: ModelRoute(upstreamModel: "fixture-luna", reasoningEffort: "low", textVerbosity: "low")) == nil)
        #expect(snapshot.validationError(for: ModelRoute(upstreamModel: "retired", reasoningEffort: "low", textVerbosity: "low")) != nil)
        #expect(snapshot.validationError(for: ModelRoute(upstreamModel: "fixture-luna", reasoningEffort: "none", textVerbosity: "low")) != nil)
        let unknown = SIWCModelSummary(id: "unknown", label: "Unknown", accountID: "account-a", details: JSONObject())
        #expect(unknown.reasoningEfforts.isEmpty)
        #expect(unknown.capabilitySummary == "Capability metadata unavailable")
        #expect(models.first?.reasoningEfforts == ["low", "high"])
        #expect(models.first?.capabilitySummary == "Parallel tool calls: Yes")
        #expect(snapshot.models.map(\.id) == ["fixture-luna"])
    }
}
