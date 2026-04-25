import Foundation
@testable import CCRouterCore
@testable import Claudex
import Testing

@MainActor
struct SettingsTokenStatusTests {
    // MARK: refreshNowTogglesBusyFlag

    @Test
    func refreshTokenNowSetsBusyFlagDuringRefreshAndClearsAfter() async throws {
        let refresher = BlockingMockRefresher()
        let model = AppModel(subscriptionRefresherFactory: { _, _ in refresher })

        #expect(model.isRefreshingToken == false)

        let refreshTask = Task { await model.refreshTokenNow() }

        try await waitUntil(timeout: .milliseconds(500)) {
            model.isRefreshingToken
        }
        #expect(model.isRefreshingToken == true)

        await refresher.release()
        await refreshTask.value

        #expect(model.isRefreshingToken == false)
    }

    // MARK: refreshFailurePopulatesError

    @Test
    func refreshFailureSetsTokenRefreshError() async {
        let failure = MockRefresherError.refreshFailed
        let refresher = BlockingMockRefresher(errorToThrow: failure)
        let model = AppModel(subscriptionRefresherFactory: { _, _ in refresher })

        Task {
            try? await Task.sleep(for: .milliseconds(10))
            await refresher.release()
        }
        await model.refreshTokenNow()

        #expect(model.tokenRefreshError == failure.localizedDescription)
    }

    // MARK: refreshTokenNow clears prior error on entry

    @Test
    func refreshTokenNowClearsPreviousErrorAtEntry() async throws {
        let firstFailure = BlockingMockRefresher(errorToThrow: MockRefresherError.refreshFailed)
        let model = AppModel(subscriptionRefresherFactory: { _, _ in firstFailure })

        Task { await firstFailure.release() }
        await model.refreshTokenNow()
        #expect(model.tokenRefreshError != nil)

        let secondRefresher = BlockingMockRefresher()
        let secondModel = AppModel(subscriptionRefresherFactory: { _, _ in secondRefresher })
        secondModel.tokenRefreshError = "stale error"

        let refreshTask = Task { await secondModel.refreshTokenNow() }

        try await waitUntil(timeout: .milliseconds(500)) {
            secondModel.isRefreshingToken
        }
        #expect(secondModel.tokenRefreshError == nil)

        await secondRefresher.release()
        await refreshTask.value
    }

    // MARK: Polling lifecycle

    @Test
    func startTokenStatusPollingExitsOnCancellation() async throws {
        let model = AppModel()
        let pollTask = Task { await model.startTokenStatusPolling() }

        try await Task.sleep(for: .milliseconds(50))

        pollTask.cancel()
        await pollTask.value
    }
}

// MARK: - Test doubles

@MainActor
private func waitUntil(
    timeout: Duration,
    predicate: @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !predicate() {
        if ContinuousClock.now - start > timeout {
            throw WaitTimeoutError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct WaitTimeoutError: Error {}

enum MockRefresherError: LocalizedError {
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .refreshFailed: return "Simulated refresh failure"
        }
    }
}

/// Mock subscription refresher that blocks in `refreshAndReload()` until `release()`
/// is called, then throws the configured error (default: authorizationRequired).
actor BlockingMockRefresher: SubscriptionSessionProviding {
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private(set) var refreshCallCount = 0
    private let errorToThrow: Error

    init(errorToThrow: Error = MockRefresherError.refreshFailed) {
        self.errorToThrow = errorToThrow
    }

    func release() {
        waitContinuation?.resume()
        waitContinuation = nil
    }

    func loadCurrent() async throws -> SubscriptionCredentials {
        throw MockRefresherError.refreshFailed
    }

    func refreshAndReload() async throws -> SubscriptionCredentials {
        refreshCallCount += 1
        await withCheckedContinuation { waitContinuation = $0 }
        throw errorToThrow
    }
}
