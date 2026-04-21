import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(
        statusCode: Int = 200,
        reasonPhrase: String = "OK",
        value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> HTTPResponse {
        let body = try encoder.encode(value)
        return HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

public final class LocalHTTPServer {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let configuration: RouterConfiguration
    private let handler: Handler
    private var listener: NWListener?

    public init(configuration: RouterConfiguration, handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(configuration.port))
        )

        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                fputs("LocalHTTPServer listener failed: \(error)\n", stderr)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [handler] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task.detached {
                await LocalHTTPServer.serve(connection: connection, handler: handler)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func serve(connection: NWConnection, handler: @escaping Handler) async {
        var buffer = Data()
        do {
            let request = try await receiveRequest(on: connection, buffer: &buffer)
            let response = await handler(request)
            try await send(response: response, on: connection)
        } catch {
            let body = Data("{\"error\":\"\(error.localizedDescription)\"}".utf8)
            let response = HTTPResponse(
                statusCode: 400,
                reasonPhrase: "Bad Request",
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
            try? await send(response: response, on: connection)
        }
        connection.cancel()
    }

    private static func receiveRequest(on connection: NWConnection, buffer: inout Data) async throws -> HTTPRequest {
        while true {
            if let request = try parseRequest(from: buffer) {
                return request
            }

            let chunk = try await receiveChunk(on: connection)
            if chunk.isEmpty {
                throw HTTPParsingError.connectionClosed
            }
            buffer.append(chunk)
        }
    }

    private static func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }

                continuation.resume(throwing: HTTPParsingError.connectionClosed)
            }
        }
    }

    private static func parseRequest(from data: Data) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParsingError.invalidUTF8
        }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            throw HTTPParsingError.missingRequestLine
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw HTTPParsingError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key.lowercased()] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let availableBodyLength = data.distance(from: bodyStart, to: data.endIndex)
        guard availableBodyLength >= contentLength else {
            return nil
        }

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = Data(data[bodyStart..<bodyEnd])

        let target = String(requestParts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        return HTTPRequest(
            method: String(requestParts[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private static func send(response: HTTPResponse, on connection: NWConnection) async throws {
        var serialized = Data("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n".utf8)
        let headers = response.headers.merging(
            [
                "Content-Length": "\(response.body.count)",
                "Connection": "close",
            ],
            uniquingKeysWith: { current, _ in current }
        )

        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            serialized.append(Data("\(key): \(value)\r\n".utf8))
        }
        serialized.append(Data("\r\n".utf8))
        serialized.append(response.body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: serialized, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

enum HTTPParsingError: Error {
    case connectionClosed
    case invalidUTF8
    case missingRequestLine
    case invalidRequestLine
}
