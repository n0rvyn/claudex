import Foundation

public struct RouterConfiguration: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let healthPath: String
    public let messagesPath: String
    public let countTokensPath: String
    public let responsesURL: String
    public let executorModel: String
    public let advisorModel: String
    public let gatewayAuthToken: String
    public let gatewayAuthHeader: String
    public let subscriptionAuthFilePath: String
    public let subscriptionAuthBookmarkData: Data?
    public let configurationPath: String
    public let configurationWarning: String?

    public init(
        host: String,
        port: Int,
        healthPath: String,
        messagesPath: String,
        countTokensPath: String,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        gatewayAuthToken: String,
        gatewayAuthHeader: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data? = nil,
        configurationPath: String,
        configurationWarning: String?
    ) {
        self.host = host
        self.port = port
        self.healthPath = healthPath
        self.messagesPath = messagesPath
        self.countTokensPath = countTokensPath
        self.responsesURL = responsesURL
        self.executorModel = executorModel
        self.advisorModel = advisorModel
        self.gatewayAuthToken = gatewayAuthToken
        self.gatewayAuthHeader = gatewayAuthHeader
        self.subscriptionAuthFilePath = subscriptionAuthFilePath
        self.subscriptionAuthBookmarkData = subscriptionAuthBookmarkData
        self.configurationPath = configurationPath
        self.configurationWarning = configurationWarning
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self = RouterConfigurationStore(
            environment: environment,
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL
        ).loadOrCreate()
    }

    public var endpoint: String {
        "http://\(host):\(port)"
    }

    public var gatewayAuthTokenSuffix: String {
        String(gatewayAuthToken.suffix(6))
    }

    public var claudeEnvironmentSnippet: String {
        "ANTHROPIC_BASE_URL=\(endpoint)\nANTHROPIC_AUTH_TOKEN=\(gatewayAuthToken)"
    }
}
