import Foundation

public actor GatewayDaemon {
    private let configuration: RouterConfiguration
    private let bridge: SIWCBridge
    private var server: LocalHTTPServer?
    private var startedAt: Date?

    public init(configuration: RouterConfiguration = RouterConfiguration(), auth: any SubscriptionSessionProviding = SIWCAuth.shared) {
        self.configuration = configuration
        self.bridge = SIWCBridge(configuration: configuration, auth: auth, replayStore: SIWCReplayStore(directory: URL(fileURLWithPath: configuration.configurationPath).deletingLastPathComponent().appendingPathComponent("Replay")))
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
        var snapshot = DoctorSnapshot(
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
        snapshot.traffic = await bridge.trafficSnapshot()
        return snapshot
    }

    public func applyRoutingUpdate(table: ModelRoutingTable, advisorRoute: ModelRoute) async {
        await bridge.updateRouting(table: table, advisorRoute: advisorRoute)
    }

    private static func route(
        request: HTTPRequest,
        configuration: RouterConfiguration,
        bridge: SIWCBridge
    ) async -> HTTPResponse {
        await ClassifierDiagnostics.observe(request) {
            await routeWithoutDiagnostics(request: request, configuration: configuration, bridge: bridge)
        }
    }

    private static func routeWithoutDiagnostics(request: HTTPRequest, configuration: RouterConfiguration, bridge: SIWCBridge) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("HEAD", "/"):
            return HTTPResponse(statusCode: 200, reasonPhrase: "OK")

        case ("GET", configuration.healthPath):
            return try! HTTPResponse.json(value: ["status": "running", "service": "Claudex"])

        case ("POST", configuration.countTokensPath):
            if let response = await rejectIfUnauthorized(request: request, configuration: configuration) {
                return response
            }
            return await bridge.handleCountTokens(request)

        case ("POST", configuration.messagesPath):
            if let response = await rejectIfUnauthorized(request: request, configuration: configuration) {
                await bridge.recordLocalAuthRejection()
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

        await TraceLogger.shared.log(
            JSONObject.from([
                "stage": .string("local_auth_reject"),
                "path": .string(request.path),
                "provided_header": .string(LocalGatewayAuthorization.expectedHeader),
                "authenticated": .bool(false),
                
            ])
        )
        return LocalGatewayAuthorization.unauthorizedResponse(
            providedSuffix: "<redacted>",
            expectedSuffix: "<redacted>"
        )
    }
}

private struct ErrorEnvelope: Codable, Sendable {
    let error: String
}
