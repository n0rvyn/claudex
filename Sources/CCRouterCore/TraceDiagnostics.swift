import Foundation

public struct TraceDiagnostics: Codable, Sendable, Equatable {
    public let recentStageCounts: [String: Int]
    public let recentFunctionCallNames: [String]
    public let recentConnectorNames: [String]
    public let recentRejectedPaths: [String]
    public let recentRequestCount: Int
    public let recentSuccessCount: Int
    public let recentFailureCount: Int
    public let requestsPerMinute: Double
    public let lastRequestOutcome: String?
    public let lastLatencyMilliseconds: Int?
    public let p50LatencyMilliseconds: Int?
    public let p95LatencyMilliseconds: Int?
    public let recentErrorReasons: [String]

    public init(
        recentStageCounts: [String: Int],
        recentFunctionCallNames: [String],
        recentConnectorNames: [String],
        recentRejectedPaths: [String],
        recentRequestCount: Int,
        recentSuccessCount: Int,
        recentFailureCount: Int,
        requestsPerMinute: Double,
        lastRequestOutcome: String?,
        lastLatencyMilliseconds: Int?,
        p50LatencyMilliseconds: Int?,
        p95LatencyMilliseconds: Int?,
        recentErrorReasons: [String]
    ) {
        self.recentStageCounts = recentStageCounts
        self.recentFunctionCallNames = recentFunctionCallNames
        self.recentConnectorNames = recentConnectorNames
        self.recentRejectedPaths = recentRejectedPaths
        self.recentRequestCount = recentRequestCount
        self.recentSuccessCount = recentSuccessCount
        self.recentFailureCount = recentFailureCount
        self.requestsPerMinute = requestsPerMinute
        self.lastRequestOutcome = lastRequestOutcome
        self.lastLatencyMilliseconds = lastLatencyMilliseconds
        self.p50LatencyMilliseconds = p50LatencyMilliseconds
        self.p95LatencyMilliseconds = p95LatencyMilliseconds
        self.recentErrorReasons = recentErrorReasons
    }

    public static let empty = TraceDiagnostics(
        recentStageCounts: [:],
        recentFunctionCallNames: [],
        recentConnectorNames: [],
        recentRejectedPaths: [],
        recentRequestCount: 0,
        recentSuccessCount: 0,
        recentFailureCount: 0,
        requestsPerMinute: 0,
        lastRequestOutcome: nil,
        lastLatencyMilliseconds: nil,
        p50LatencyMilliseconds: nil,
        p95LatencyMilliseconds: nil,
        recentErrorReasons: []
    )
}
