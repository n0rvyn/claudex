import Foundation
import Network
@testable import CCRouterCore
import Testing

@Suite(.serialized)
struct LocalHTTPServerStreamingErrorTests {
    @Test
    func committedStreamFailureDoesNotAppendSecondHTTPResponse() async throws {
        try await TraceIsolation.withInstanceOverride {
            let (server, port) = try await Self.startServerWithRetry { port in
                let bridge = AnthropicBridge(
                    configuration: Self.makeConfiguration(port: port),
                    responsesClient: MockResponsesClient(streams: [
                        MockResponsesEventStream.textThenError(
                            partialText: "partial text before reset",
                            error: NSError(
                                domain: "LocalHTTPServerStreamingErrorTests",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "connection reset"]
                            )
                        ),
                    ]),
                    sessionLoader: MockSessionLoader(
                        credentials: SubscriptionCredentials(accessToken: "test-token", accountID: "test-account")
                    )
                )
                return LocalHTTPServer(configuration: Self.makeConfiguration(port: port)) { request in
                    await bridge.handleMessages(request)
                }
            }
            defer { server.stop() }

            let body = try JSONEncoder().encode(
                AnthropicMessagesRequest(
                    model: "claude-4-sonnet",
                    max_tokens: 512,
                    messages: [
                        AnthropicMessage(role: "user", content: [
                            JSONObject.from([
                                "type": .string("text"),
                                "text": .string("Say hello"),
                            ]),
                        ]),
                    ],
                    system: nil,
                    tools: nil,
                    thinking: nil,
                    context_management: nil,
                    metadata: nil,
                    output_config: nil,
                    stream: true
                )
            )
            let rawResponse = try RawLoopbackHTTPClient.fetch(
                request: Self.makeRawRequest(path: "/v1/messages", body: body),
                host: "127.0.0.1",
                port: port
            )

            let responseString = String(decoding: rawResponse, as: UTF8.self)
            #expect(Self.countOccurrences(of: "HTTP/1.1 200 OK", in: responseString) == 1)
            #expect(responseString.contains("[upstream error: connection reset]"))
            #expect(rawResponse.range(of: Data("0\r\n\r\n".utf8)) != nil)
            #expect(!responseString.contains("HTTP/1.1 400 Bad Request"))
            #expect(!responseString.contains("{\"error\":"))
        }
    }

    @Test
    func preCommitFailureStillReturnsSingle400JSONResponse() async throws {
        try await TraceIsolation.withInstanceOverride {
            let (server, port) = try await Self.startServerWithRetry { port in
                LocalHTTPServer(configuration: Self.makeConfiguration(port: port)) { _ in
                    HTTPResponse(statusCode: 200, reasonPhrase: "OK", body: Data())
                }
            }
            defer { server.stop() }

            let rawResponse = try RawLoopbackHTTPClient.fetch(
                request: Data("BROKEN\r\n\r\n".utf8),
                host: "127.0.0.1",
                port: port
            )

            let responseString = String(decoding: rawResponse, as: UTF8.self)
            #expect(Self.countOccurrences(of: "HTTP/1.1 400 Bad Request", in: responseString) == 1)
            #expect(!responseString.contains("HTTP/1.1 200 OK"))
            #expect(responseString.contains("Content-Type: application/json; charset=utf-8"))
            #expect(responseString.contains("{\"error\":"))
        }
    }

    private static func makeConfiguration(port: UInt16) -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1",
            port: Int(port),
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: "executor-upstream", reasoningEffort: "high", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: "advisor-upstream", reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
    }

    private static func makeRawRequest(path: String, body: Data) -> Data {
        var request = Data("POST \(path) HTTP/1.1\r\n".utf8)
        request.append(Data("Host: 127.0.0.1\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n".utf8))
        request.append(Data("\r\n".utf8))
        request.append(body)
        return request
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func startServerWithRetry(
        makeServer: (UInt16) -> LocalHTTPServer
    ) async throws -> (server: LocalHTTPServer, port: UInt16) {
        var lastError: Error?
        for attempt in 0..<2 {
            let port = try reserveLoopbackPort()
            let server = makeServer(port)
            do {
                try server.start()
                try await Task.sleep(for: .milliseconds(100))
                return (server, port)
            } catch let error as NWError {
                server.stop()
                lastError = error
                if case .posix(let code) = error, code == .EADDRINUSE, attempt == 0 {
                    continue
                }
                throw error
            } catch let error as POSIXError {
                server.stop()
                lastError = error
                if error.code == .EADDRINUSE, attempt == 0 {
                    continue
                }
                throw error
            } catch {
                server.stop()
                lastError = error
                throw error
            }
        }
        throw lastError ?? POSIXError(.EADDRINUSE)
    }
}
