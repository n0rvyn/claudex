import Foundation

public actor GatewayDaemon {
    private let configuration: RouterConfiguration
    private let bridge: AnthropicBridge
    private var server: LocalHTTPServer?
    private var startedAt: Date?

    public init(configuration: RouterConfiguration = RouterConfiguration()) {
        self.configuration = configuration
        self.bridge = AnthropicBridge(
            configuration: configuration,
            sessionLoader: SubscriptionSessionLoader(
                authFileURL: URL(fileURLWithPath: configuration.subscriptionAuthFilePath),
                securityScopedBookmarkData: configuration.subscriptionAuthBookmarkData
            )
        )
    }

    public func start() throws {
        guard server == nil else { return }

        let bridge = self.bridge
        let server = LocalHTTPServer(configuration: configuration) { [configuration] request in
            await GatewayDaemon.route(request: request, configuration: configuration, bridge: bridge)
        }
        try server.start()
        self.server = server
        self.startedAt = Date()
    }

    public func stop() {
        server?.stop()
        server = nil
        startedAt = nil
    }

    public func snapshot() async -> DoctorSnapshot {
        let auth = await bridge.doctorStatus()
        let tracePath = await TraceLogger.shared.path
        let recentTraceLines = await TraceLogger.shared.recentLines(limit: 8)
        let traceDiagnostics = await TraceLogger.shared.diagnostics(limit: 64)
        return DoctorSnapshot(
            host: configuration.host,
            port: configuration.port,
            daemonState: server == nil ? "stopped" : "running",
            startedAt: startedAt,
            anthropicMessagesPath: configuration.messagesPath,
            countTokensPath: configuration.countTokensPath,
            messagesImplemented: true,
            countTokensImplemented: true,
            countTokensStrategy: "body-size-heuristic",
            responsesURL: configuration.responsesURL,
            executorModel: configuration.executorModel,
            advisorModel: configuration.advisorModel,
            gatewayAuthHeader: configuration.gatewayAuthHeader,
            gatewayAuthTokenSuffix: configuration.gatewayAuthTokenSuffix,
            configurationPath: configuration.configurationPath,
            configurationWarning: configuration.configurationWarning,
            subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
            authState: auth.authState,
            chatGPTAuthenticated: auth.chatGPTAuthenticated,
            accountIDSuffix: auth.accountIDSuffix,
            authError: auth.authError,
            tracePath: tracePath,
            recentTraceLines: recentTraceLines
            ,
            traceDiagnostics: traceDiagnostics
        )
    }

    private static func route(
        request: HTTPRequest,
        configuration: RouterConfiguration,
        bridge: AnthropicBridge
    ) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("HEAD", "/"):
            return HTTPResponse(statusCode: 200, reasonPhrase: "OK")

        case ("GET", configuration.healthPath):
            let auth = await bridge.doctorStatus()
            let tracePath = await TraceLogger.shared.path
            let recentTraceLines = await TraceLogger.shared.recentLines(limit: 8)
            let traceDiagnostics = await TraceLogger.shared.diagnostics(limit: 64)
            let snapshot = DoctorSnapshot(
                host: configuration.host,
                port: configuration.port,
                daemonState: "running",
                startedAt: Date(),
                anthropicMessagesPath: configuration.messagesPath,
                countTokensPath: configuration.countTokensPath,
                messagesImplemented: true,
                countTokensImplemented: true,
                countTokensStrategy: "body-size-heuristic",
                responsesURL: configuration.responsesURL,
                executorModel: configuration.executorModel,
                advisorModel: configuration.advisorModel,
                gatewayAuthHeader: configuration.gatewayAuthHeader,
                gatewayAuthTokenSuffix: configuration.gatewayAuthTokenSuffix,
                configurationPath: configuration.configurationPath,
                configurationWarning: configuration.configurationWarning,
                subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
                authState: auth.authState,
                chatGPTAuthenticated: auth.chatGPTAuthenticated,
                accountIDSuffix: auth.accountIDSuffix,
                authError: auth.authError,
                tracePath: tracePath,
                recentTraceLines: recentTraceLines,
                traceDiagnostics: traceDiagnostics
            )
            return try! HTTPResponse.json(value: snapshot)

        case ("POST", configuration.countTokensPath):
            guard LocalGatewayAuthorization.isAuthorized(
                headers: request.headers,
                expectedToken: configuration.gatewayAuthToken
            ) else {
                await TraceLogger.shared.log(
                    JSONObject.from([
                        "stage": .string("local_auth_reject"),
                        "path": .string(request.path),
                        "provided_header": .string(LocalGatewayAuthorization.expectedHeader),
                    ])
                )
                return LocalGatewayAuthorization.unauthorizedResponse()
            }
            let heuristic = max(1, request.body.count / 4)
            let response = CountTokensResponse(input_tokens: heuristic)
            return try! HTTPResponse.json(value: response)

        case ("POST", configuration.messagesPath):
            guard LocalGatewayAuthorization.isAuthorized(
                headers: request.headers,
                expectedToken: configuration.gatewayAuthToken
            ) else {
                await TraceLogger.shared.log(
                    JSONObject.from([
                        "stage": .string("local_auth_reject"),
                        "path": .string(request.path),
                        "provided_header": .string(LocalGatewayAuthorization.expectedHeader),
                    ])
                )
                return LocalGatewayAuthorization.unauthorizedResponse()
            }
            return await bridge.handleMessages(request)

        default:
            fputs("Unhandled route \(request.method) \(request.path)\n", stderr)
            let error = ErrorEnvelope(error: "route not found")
            return try! HTTPResponse.json(
                statusCode: 404,
                reasonPhrase: "Not Found",
                value: error
            )
        }
    }
}

private struct CountTokensResponse: Codable, Sendable {
    let input_tokens: Int
}

private struct ErrorEnvelope: Codable, Sendable {
    let error: String
}
