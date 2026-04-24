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

    /// Body is either a pre-buffered Data block or a streaming producer.
    public let body: Body

    /// Enum representing the two body forms.
    public enum Body: Sendable {
        case data(Data)
        case stream(@Sendable (HTTPBodyWriter) async throws -> Void)
    }

    /// Backward-compat accessor — returns the buffered Data if the body is
    /// `.data`, or nil if it is `.stream`.
    public var bodyData: Data? {
        if case .data(let d) = body { return d }
        return nil
    }

    // MARK: - Convenience initialisers

    /// Existing Data-body initialiser — wraps to `.data`.
    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .data(body)
    }

    /// New streaming initialiser for streaming responses (e.g. SSE).
    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        stream producer: @Sendable @escaping (HTTPBodyWriter) async throws -> Void
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .stream(producer)
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

/// Protocol for writing streaming HTTP body chunks.
///
/// Implementations wrap the concrete transport (e.g. NWConnection for the
/// local daemon) and format bytes according to the transfer encoding in use.
public protocol HTTPBodyWriter: Sendable {
    /// Writes a single data chunk. For chunked transfer encoding this formats
    /// the chunk as `<hex-size>\r\n<data>\r\n`.
    func write(_ chunk: Data) async throws

    /// Signals the end of the body. For chunked transfer encoding this sends
    /// the terminating chunk `0\r\n\r\n`.
    func finish() async throws
}

/// Wire-format helpers for chunked-transfer-encoded HTTP responses.
///
/// These are pure functions on Data/String: no sockets, no connections.
/// Extracted so unit tests can assert the exact header + chunk bytes that go
/// on the wire without standing up a loopback server.
internal enum ChunkedHTTPEncoder {
    /// Builds the HTTP/1.1 response header bytes for a streaming response.
    ///
    /// The returned data terminates with `\r\n\r\n`. Transfer-Encoding is set
    /// to `chunked` and Connection to `close`; any user-supplied
    /// `Content-Length` header is filtered out per RFC 9112 §6.2 (when
    /// Transfer-Encoding is present, Content-Length MUST NOT be sent).
    static func buildHeaderBytes(
        statusCode: Int,
        reasonPhrase: String,
        userHeaders: [String: String]
    ) -> Data {
        var headerBytes = Data("HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n".utf8)

        let filteredHeaders = userHeaders.filter { key, _ in
            key.lowercased() != "content-length"
        }.merging(
            ["Transfer-Encoding": "chunked", "Connection": "close"],
            uniquingKeysWith: { _, new in new }
        )

        for key in filteredHeaders.keys.sorted() {
            guard let value = filteredHeaders[key] else { continue }
            headerBytes.append(Data("\(key): \(value)\r\n".utf8))
        }
        headerBytes.append(Data("\r\n".utf8))
        return headerBytes
    }

    /// Formats one chunk as `<hex-size>\r\n<bytes>\r\n` per RFC 9112 §7.1.
    static func formatChunk(_ chunk: Data) -> Data {
        let hex = String(chunk.count, radix: 16)
        var data = Data("\(hex)\r\n".utf8)
        data.append(chunk)
        data.append(Data("\r\n".utf8))
        return data
    }

    /// The terminating chunk `0\r\n\r\n` ending a chunked body.
    static let terminator: Data = Data("0\r\n\r\n".utf8)
}

/// Wraps an `NWConnection` and writes chunked-transfer-encoded chunks.
private struct NWConnectionBodyWriter: HTTPBodyWriter {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func write(_ chunk: Data) async throws {
        let data = ChunkedHTTPEncoder.formatChunk(chunk)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func finish() async throws {
        let terminator = ChunkedHTTPEncoder.terminator
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: terminator, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

private enum ResponseWriteError: Error {
    case committedStreamFailure(underlying: Error)
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

        // Disable Nagle so the first chunk of a streaming response reaches the
        // client within 50 ms of the first upstream SSE event.
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }

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
        } catch let error as ResponseWriteError {
            switch error {
            case .committedStreamFailure(let underlying):
                fputs("LocalHTTPServer committed stream failure: \(underlying)\n", stderr)
            }
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

    // MARK: - Response sending

    private static func send(response: HTTPResponse, on connection: NWConnection) async throws {
        switch response.body {
        case .data(let data):
            try await sendDataBody(response: response, body: data, connection: connection)
        case .stream(let producer):
            try await sendStreamBody(response: response, producer: producer, connection: connection)
        }
    }

    /// Sends a pre-buffered Data body with Content-Length and Connection: close.
    private static func sendDataBody(
        response: HTTPResponse,
        body: Data,
        connection: NWConnection
    ) async throws {
        var serialized = Data("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n".utf8)
        let headers = response.headers.merging(
            [
                "Content-Length": "\(body.count)",
                "Connection": "close",
            ],
            uniquingKeysWith: { current, _ in current }
        )

        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            serialized.append(Data("\(key): \(value)\r\n".utf8))
        }
        serialized.append(Data("\r\n".utf8))
        serialized.append(body)

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

    /// Sends a streaming body using chunked transfer encoding (RFC 9112 §7.1).
    /// Explicitly excludes Content-Length from the headers; Transfer-Encoding
    /// takes precedence per RFC 9112 §6.2.
    private static func sendStreamBody(
        response: HTTPResponse,
        producer: @escaping (HTTPBodyWriter) async throws -> Void,
        connection: NWConnection
    ) async throws {
        let headerBytes = ChunkedHTTPEncoder.buildHeaderBytes(
            statusCode: response.statusCode,
            reasonPhrase: response.reasonPhrase,
            userHeaders: response.headers
        )

        do {
            // Send the full header (terminating blank line included).
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: headerBytes, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }

            // Invoke the body producer with a chunked writer.
            let writer = NWConnectionBodyWriter(connection: connection)
            do {
                try await producer(writer)
                // Success path: emit the terminating chunk `0\r\n\r\n` so the client
                // sees a clean end-of-body per RFC 9112 §7.1. Without this, HTTP
                // clients report "socket closed unexpectedly" even though the SSE
                // payload was complete.
                try await writer.finish()
            } catch {
                try? await writer.finish()
                throw ResponseWriteError.committedStreamFailure(underlying: error)
            }
        } catch let error as ResponseWriteError {
            throw error
        } catch {
            throw ResponseWriteError.committedStreamFailure(underlying: error)
        }
    }
}

enum HTTPParsingError: Error {
    case connectionClosed
    case invalidUTF8
    case missingRequestLine
    case invalidRequestLine
}
