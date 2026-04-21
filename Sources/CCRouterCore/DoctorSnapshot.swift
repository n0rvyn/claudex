import Foundation

public struct DoctorSnapshot: Codable, Sendable {
    public let host: String
    public let port: Int
    public let daemonState: String
    public let startedAt: Date?
    public let anthropicMessagesPath: String
    public let countTokensPath: String
    public let messagesImplemented: Bool
    public let countTokensImplemented: Bool
    public let countTokensStrategy: String
    public let responsesURL: String
    public let executorModel: String
    public let advisorModel: String
    public let gatewayAuthHeader: String
    public let gatewayAuthTokenSuffix: String
    public let configurationPath: String
    public let configurationWarning: String?
    public let subscriptionAuthFilePath: String
    public let authState: SubscriptionAuthState
    public let chatGPTAuthenticated: Bool
    public let accountIDSuffix: String?
    public let authError: String?
    public let tracePath: String
    public let recentTraceLines: [String]
    public let traceDiagnostics: TraceDiagnostics

    public init(
        host: String,
        port: Int,
        daemonState: String,
        startedAt: Date?,
        anthropicMessagesPath: String,
        countTokensPath: String,
        messagesImplemented: Bool,
        countTokensImplemented: Bool,
        countTokensStrategy: String,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        gatewayAuthHeader: String,
        gatewayAuthTokenSuffix: String,
        configurationPath: String,
        configurationWarning: String?,
        subscriptionAuthFilePath: String,
        authState: SubscriptionAuthState,
        chatGPTAuthenticated: Bool,
        accountIDSuffix: String?,
        authError: String?,
        tracePath: String,
        recentTraceLines: [String],
        traceDiagnostics: TraceDiagnostics
    ) {
        self.host = host
        self.port = port
        self.daemonState = daemonState
        self.startedAt = startedAt
        self.anthropicMessagesPath = anthropicMessagesPath
        self.countTokensPath = countTokensPath
        self.messagesImplemented = messagesImplemented
        self.countTokensImplemented = countTokensImplemented
        self.countTokensStrategy = countTokensStrategy
        self.responsesURL = responsesURL
        self.executorModel = executorModel
        self.advisorModel = advisorModel
        self.gatewayAuthHeader = gatewayAuthHeader
        self.gatewayAuthTokenSuffix = gatewayAuthTokenSuffix
        self.configurationPath = configurationPath
        self.configurationWarning = configurationWarning
        self.subscriptionAuthFilePath = subscriptionAuthFilePath
        self.authState = authState
        self.chatGPTAuthenticated = chatGPTAuthenticated
        self.accountIDSuffix = accountIDSuffix
        self.authError = authError
        self.tracePath = tracePath
        self.recentTraceLines = recentTraceLines
        self.traceDiagnostics = traceDiagnostics
    }
}
