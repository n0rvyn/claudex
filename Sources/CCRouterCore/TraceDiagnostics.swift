import Foundation

public struct TraceDiagnostics: Codable, Sendable, Equatable {
    public let recentStageCounts: [String: Int]
    public let recentFunctionCallNames: [String]
    public let recentConnectorNames: [String]
    public let recentRejectedPaths: [String]

    public init(
        recentStageCounts: [String: Int],
        recentFunctionCallNames: [String],
        recentConnectorNames: [String],
        recentRejectedPaths: [String]
    ) {
        self.recentStageCounts = recentStageCounts
        self.recentFunctionCallNames = recentFunctionCallNames
        self.recentConnectorNames = recentConnectorNames
        self.recentRejectedPaths = recentRejectedPaths
    }

    public static let empty = TraceDiagnostics(
        recentStageCounts: [:],
        recentFunctionCallNames: [],
        recentConnectorNames: [],
        recentRejectedPaths: []
    )
}
