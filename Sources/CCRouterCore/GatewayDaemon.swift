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
            countTokensStrategy: "cl100k-bpe",
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
            lastRefresh: auth.lastRefresh,
            hasRefreshToken: auth.hasRefreshToken,
            accessTokenPreview: auth.accessTokenPreview,
            tracePath: tracePath,
            recentTraceLines: recentTraceLines,
            traceDiagnostics: traceDiagnostics,
            pendingToolTurnsCount: await bridge.pendingToolTurnsCount()
        )
    }

    public func applyRoutingUpdate(table: ModelRoutingTable, advisorRoute: ModelRoute) async {
        await bridge.updateRouting(table: table, advisorRoute: advisorRoute)
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
                countTokensStrategy: "cl100k-bpe",
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
                lastRefresh: auth.lastRefresh,
                hasRefreshToken: auth.hasRefreshToken,
                accessTokenPreview: auth.accessTokenPreview,
                tracePath: tracePath,
                recentTraceLines: recentTraceLines,
                traceDiagnostics: traceDiagnostics,
                pendingToolTurnsCount: await bridge.pendingToolTurnsCount()
            )
            return try! HTTPResponse.json(value: snapshot)

        case ("POST", configuration.countTokensPath):
            if let response = await rejectIfUnauthorized(request: request, configuration: configuration) {
                return response
            }
            return await bridge.handleCountTokens(request)

        case ("POST", configuration.messagesPath):
            if let response = await rejectIfUnauthorized(request: request, configuration: configuration) {
                return response
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

    private static func rejectIfUnauthorized(
        request: HTTPRequest,
        configuration: RouterConfiguration
    ) async -> HTTPResponse? {
        let provided = LocalGatewayAuthorization.providedToken(from: request.headers)
        guard provided != configuration.gatewayAuthToken else { return nil }

        let providedSuffix = LocalGatewayAuthorization.tokenSuffix(provided)
        let expectedSuffix = LocalGatewayAuthorization.tokenSuffix(configuration.gatewayAuthToken)
        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("local_auth_reject"),
                "path": .string(request.path),
                "provided_header": .string(LocalGatewayAuthorization.expectedHeader),
                "provided_token_suffix": .string(providedSuffix),
                "expected_token_suffix": .string(expectedSuffix),
            ])
        )
        return LocalGatewayAuthorization.unauthorizedResponse(
            providedSuffix: providedSuffix,
            expectedSuffix: expectedSuffix
        )
    }
}

private struct ErrorEnvelope: Codable, Sendable {
    let error: String
}
