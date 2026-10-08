import Foundation
import Network

/// Explicitly started by the user's Continue with ChatGPT action.
/// Creates the loopback listener before preparing the browser authorization URL.
@MainActor
public final class SIWCSignIn {
    private let auth: SIWCAuth
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var attempt: SIWCAttempt?
    private var connections: [UUID: NWConnection] = [:]
    public var onCompletion: ((Result<Void, Error>) -> Void)?
    public init(auth: SIWCAuth = .shared) { self.auth = auth }
    public func start(accountID: String? = nil) async throws -> URL {
        await cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { @MainActor in
                guard let self, let pending = self.attempt else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                await self.receive(connection, pending: pending)
                self.connections.removeValue(forKey: id)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready = ListenerReady()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.finish(continuation, error: nil)
                case .failed(let error): ready.finish(continuation, error: error)
                case .cancelled: ready.finish(continuation, error: CancellationError())
                default: break
                }
            }
            listener.start(queue: .global())
        }
        guard let port = listener.port else { await cancel(); throw SIWCError.invalidCallback }
        let pending: SIWCAttempt
        do { pending = try await auth.begin(redirectURI: "http://127.0.0.1:\(port.rawValue)/auth/callback", accountID: accountID) }
        catch { await cancel(); throw error }
        attempt = pending
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(SIWCError.expiredAttempt))
        }
        return pending.authorizationURL
    }
    public func cancel() async {
        timeout?.cancel(); timeout = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        listener?.cancel(); listener = nil; attempt = nil
        await auth.cancelSignIn()
    }
    private func receive(_ connection: NWConnection, pending: SIWCAttempt) async {
        defer { connection.cancel() }
        do {
            var buffer = Data()
            while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if complete && (data?.isEmpty ?? true) { continuation.resume(throwing: SIWCError.invalidCallback) }
                        else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                buffer.append(data)
                guard buffer.count <= 16_384 else { throw SIWCError.invalidCallback }
            }
            guard let head = String(data: buffer, encoding: .utf8)?.components(separatedBy: "\r\n").first else { throw SIWCError.invalidCallback }
            let parts = head.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
                  parts[1].hasPrefix("/auth/callback?"),
                  let origin = URLComponents(string: pending.redirectURI), let host = origin.host, let port = origin.port,
                  let callback = URL(string: "http://\(host):\(port)" + parts[1]) else { throw SIWCError.invalidCallback }
            try await auth.complete(callback: callback)
            let body = "Claudex sign-in complete. You can close this window."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            await finish(.success(()))
        } catch {
            // An unrelated or forged local request cannot cancel the pending login.
            if case SIWCError.invalidCallback = error { return }
            await finish(.failure(error))
        }
    }
    private func finish(_ result: Result<Void, Error>) async {
        await cancel(); onCompletion?(result)
    }
}
private final class ListenerReady: @unchecked Sendable {
    private let lock = NSLock(); private var finished = false
    func finish(_ continuation: CheckedContinuation<Void, Error>, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }; finished = true
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
