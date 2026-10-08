import Foundation
import CryptoKit
import Security
import Darwin

public enum SIWCError: Error, LocalizedError, Sendable {
    case signInRequired, invalidCallback, expiredAttempt, invalidIdentity, permissionRequired
    case unsupported(String), remote(String), storage
    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Continue with ChatGPT in Claudex Settings to authorize this app. Codex credentials are not imported."
        case .invalidCallback: "Sign-in callback did not match the pending authorization."
        case .expiredAttempt: "Sign-in expired. Start a new authorization."
        case .invalidIdentity: "ChatGPT identity could not be verified. No credentials were saved."
        case .permissionRequired: "ChatGPT plan usage permission was not granted."
        case .unsupported(let name): "Unsupported ChatGPT-plan capability: \(name)."
        case .remote(let code): "ChatGPT request failed (\(code)). No API billing fallback was used."
        case .storage: "Protected Claudex credential storage is unavailable."
        }
    }
}

public struct SIWCAccount: Codable, Sendable, Identifiable {
    public var id: String { clientID + ":" + subject }
    public let clientID: String
    public let subject: String
    public let email: String?
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var scopes: [String]
    public var expiresAt: Date
}

struct SIWCState: Codable, Sendable {
    var hostID: String = "urn:uuid:" + UUID().uuidString.lowercased()
    var accounts: [SIWCAccount] = []
    var activeID: String?
}

/// One app-owned store; owner-only atomic writes and an advisory process lock.
/// The lock spans read/refresh/write, so daemon and app cannot rotate the same token concurrently.
public final class SIWCStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL = SIWCStore.defaultDirectory) { self.directory = directory }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudex/SIWC", isDirectory: true)
    }
    func acquire() async throws -> Int32 {
        try await Task.detached { [directory] in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try SIWCStore.validateDirectory(directory)
        let fd = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else { if fd >= 0 { close(fd) }; throw SIWCError.storage }
        return fd
        }.value
    }
    static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw SIWCError.storage }
    }
    func release(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
    func read() throws -> SIWCState {
        let url = directory.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SIWCState() }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw SIWCError.storage }
        return try JSONDecoder().decode(SIWCState.self, from: Data(contentsOf: url))
    }
    func write(_ state: SIWCState) throws {
        let temporary = directory.appendingPathComponent(".accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SIWCError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(state))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw SIWCError.storage }
        guard rename(temporary.path, directory.appendingPathComponent("accounts.json").path) == 0 else {
            throw SIWCError.storage
        }
    }
}

public protocol SIWCHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
public struct SIWCURLHTTP: SIWCHTTP {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let session = URLSession(configuration: .ephemeral, delegate: SIWCNoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SIWCError.remote("invalid_response") }
        return (data, status)
    }
}

public struct SIWCAttempt: Sendable {
    public let authorizationURL: URL
    public let redirectURI: String
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String?
    let expectedSubject: String?
    let deadline: Date
}

public actor SIWCAuth: SubscriptionSessionProviding {
    public static let shared = SIWCAuth()
    private let store: SIWCStore
    private let http: any SIWCHTTP
    private var attempt: SIWCAttempt?
    private var signInGeneration = 0
    private var refreshTask: (accountID: String, leaseID: UUID, task: Task<SubscriptionCredentials, Error>)?
    public init(store: SIWCStore = SIWCStore(), http: any SIWCHTTP = SIWCURLHTTP()) {
        self.store = store; self.http = http
    }
    private static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SIWCError.storage }
        return Data(bytes).base64URL
    }
    public func begin(redirectURI: String, accountID: String? = nil) async throws -> SIWCAttempt {
        signInGeneration += 1
        let generation = signInGeneration
        guard let callback = URLComponents(string: redirectURI), callback.scheme == "http",
              callback.host == "127.0.0.1", callback.port != nil,
              callback.path == "/auth/callback", callback.query == nil, callback.fragment == nil,
              callback.user == nil, callback.password == nil else { throw SIWCError.invalidCallback }
        let fd = try await store.acquire(); defer { store.release(fd) }
        guard generation == signInGeneration else { throw CancellationError() }
        let state = try store.read()
        let selected = accountID.flatMap { id in state.accounts.first { $0.id == id } }
        if accountID != nil && selected == nil { throw SIWCError.invalidIdentity }
        try store.write(state) // stable host ID exists before opening authorization
        let verifier = try Self.random(), nonce = try Self.random(), csrf = try Self.random()
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var params = ["client_id": selected?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": state.hostID,
                      "response_type": "code", "redirect_uri": redirectURI, "scope": Self.scope,
                      "resource": Self.resource, "state": csrf, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if selected == nil { params["agent_name_hint"] = "Claudex" }
        if let hint = selected?.idToken { params["id_token_hint"] = hint }
        url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let pending = SIWCAttempt(authorizationURL: url.url!, redirectURI: redirectURI, state: csrf,
            nonce: nonce, verifier: verifier, clientID: selected?.clientID,
            expectedSubject: selected?.subject, deadline: Date().addingTimeInterval(300))
        attempt = pending
        return pending
    }
    public func cancelSignIn() { signInGeneration += 1; attempt = nil }
    public func complete(callback: URL) async throws {
        let generation = signInGeneration
        guard let pending = attempt else { throw SIWCError.invalidCallback }
        guard Date() < pending.deadline else { attempt = nil; throw SIWCError.expiredAttempt }
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let base = URLComponents(string: pending.redirectURI), components.scheme == base.scheme,
              components.host == base.host, components.port == base.port, components.path == base.path,
              components.user == nil, components.password == nil, components.fragment == nil else { throw SIWCError.invalidCallback }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw SIWCError.invalidCallback }
            query[item.name] = value
        }
        guard query["state"] == pending.state else { throw SIWCError.invalidCallback }
        attempt = nil // single-use even on denied consent or failed exchange
        if query["error"] != nil { throw SIWCError.permissionRequired }
        guard let code = query["code"], !code.isEmpty,
              let client = pending.clientID ?? query["client_id"], !client.isEmpty,
              client != "dynamic_agent_client",
              query["client_id"] == nil || query["client_id"] == client else { throw SIWCError.invalidCallback }
        let tokens = try await exchange(["grant_type": "authorization_code", "client_id": client,
            "code": code, "code_verifier": pending.verifier, "redirect_uri": pending.redirectURI, "resource": Self.resource])
        guard generation == signInGeneration else { throw CancellationError() }
        let identity = try await validateIDToken(tokens.idToken, clientID: client, nonce: pending.nonce)
        guard pending.expectedSubject == nil || pending.expectedSubject == identity.subject else { throw SIWCError.invalidIdentity }
        try validateScopes(tokens.scopes)
        let account = SIWCAccount(clientID: client, subject: identity.subject, email: identity.email,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, idToken: tokens.idToken,
            scopes: tokens.scopes, expiresAt: Date().addingTimeInterval(tokens.expiresIn))
        let fd = try await store.acquire(); defer { store.release(fd) }
        guard generation == signInGeneration else { throw CancellationError() }
        var state = try store.read()
        state.accounts.removeAll { $0.id == account.id }; state.accounts.append(account); state.activeID = account.id
        try store.write(state)
    }
    public func accounts() async throws -> [SIWCAccountSummary] {
        let fd = try await store.acquire(); defer { store.release(fd) }
        let state = try store.read()
        return state.accounts.map { SIWCAccountSummary(id: $0.id, label: $0.email ?? "ChatGPT account",
            clientID: $0.clientID, active: $0.id == state.activeID, authorized: !$0.accessToken.isEmpty) }
    }
    public func select(_ id: String) async throws {
        let fd = try await store.acquire(); defer { store.release(fd) }
        var state = try store.read()
        guard state.accounts.contains(where: { $0.id == id }) else { throw SIWCError.invalidIdentity }
        state.activeID = id; try store.write(state)
    }
    public func loadCurrent() async throws -> SubscriptionCredentials {
        let fd = try await store.acquire()
        let state: SIWCState
        do { state = try store.read() } catch { store.release(fd); throw error }
        store.release(fd)
        guard let account = state.accounts.first(where: { $0.id == state.activeID }), !account.accessToken.isEmpty else { throw SIWCError.signInRequired }
        try validateScopes(account.scopes)
        if account.expiresAt.timeIntervalSinceNow < 60 { return try await refreshAndReload() }
        return SubscriptionCredentials(accessToken: account.accessToken, accountID: account.id)
    }
    public func refreshAndReload() async throws -> SubscriptionCredentials {
        let fd = try await store.acquire()
        let state: SIWCState
        do { state = try store.read() } catch { store.release(fd); throw error }
        store.release(fd)
        guard let accountID = state.activeID else { throw SIWCError.signInRequired }
        if let refreshTask, refreshTask.accountID == accountID { return try await refreshTask.task.value }
        let leaseID = UUID()
        let task = Task { try await self.refreshLocked(expectedAccountID: accountID) }
        refreshTask = (accountID, leaseID, task)
        defer { if refreshTask?.leaseID == leaseID { refreshTask = nil } }
        return try await task.value
    }
    private func refreshLocked(expectedAccountID: String) async throws -> SubscriptionCredentials {
        let fd = try await store.acquire(); defer { store.release(fd) }
        var state = try store.read()
        guard state.activeID == expectedAccountID else { throw SIWCError.remote("account_changed") }
        guard let index = state.accounts.firstIndex(where: { $0.id == expectedAccountID }),
              let refresh = state.accounts[index].refreshToken else { throw SIWCError.signInRequired }
        var account = state.accounts[index]
        guard !account.accessToken.isEmpty else { throw SIWCError.signInRequired }
        try validateScopes(account.scopes)
        // A second process that waited on the lock uses the first process's fresh token.
        if account.expiresAt.timeIntervalSinceNow > 60 {
            return SubscriptionCredentials(accessToken: account.accessToken, accountID: account.id)
        }
        let tokens = try await exchange(["grant_type": "refresh_token", "client_id": account.clientID,
            "refresh_token": refresh, "resource": Self.resource])
        try validateScopes(tokens.scopes)
        if let idToken = tokens.idToken {
            let identity = try await validateIDToken(idToken, clientID: account.clientID, nonce: nil)
            guard identity.subject == account.subject else { throw SIWCError.invalidIdentity }
            account.idToken = idToken
        }
        account.accessToken = tokens.accessToken; account.refreshToken = tokens.refreshToken ?? refresh
        account.scopes = tokens.scopes; account.expiresAt = Date().addingTimeInterval(tokens.expiresIn)
        state.accounts[index] = account
        try store.write(state) // no use of rotated token until its replacement is durable
        return SubscriptionCredentials(accessToken: account.accessToken, accountID: account.id)
    }
    public func signOut(_ id: String) async throws -> Bool {
        let fd = try await store.acquire(); defer { store.release(fd) }
        var state = try store.read()
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw SIWCError.invalidIdentity }
        let account = state.accounts[index]
        var revoked = account.refreshToken == nil
        if let refresh = account.refreshToken {
            do {
                let discovery = try await getJSON(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
                guard let endpoint = discovery["revocation_endpoint"] as? String,
                      let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else { throw SIWCError.invalidIdentity }
                let (_, status) = try await http.send(Self.formRequest(url, ["token": refresh,
                    "token_type_hint": "refresh_token", "client_id": account.clientID]))
                revoked = status == 200
            } catch { revoked = false }
        }
        state.accounts[index].accessToken = ""; state.accounts[index].refreshToken = nil; state.accounts[index].idToken = nil
        if state.activeID == id { state.activeID = nil }
        try store.write(state)
        return revoked
    }
    /// Used after account changes or explicit refresh; never selects a model or runs inference.
    public func availableModels() async throws -> [SIWCModelSummary] {
        let credentials = try await loadCurrent()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        let (data, status) = try await http.send(request)
        guard status == 200 else { throw SIWCError.remote("model_catalog_\(status)") }
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]] else { throw SIWCError.remote("invalid_model_catalog") }
        return models.compactMap { model in
            guard model["visibility"] as? String == "list", let slug = model["slug"] as? String else { return nil }
            guard let encoded = try? JSONSerialization.data(withJSONObject: model),
                  let details = try? JSONDecoder().decode(JSONObject.self, from: encoded) else { return nil }
            return SIWCModelSummary(id: slug, label: model["display_name"] as? String ?? slug, accountID: credentials.accountID, details: details)
        }
    }
    private func validateScopes(_ scopes: [String]) throws {
        guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke") else { throw SIWCError.permissionRequired }
    }
    struct Tokens {
        let accessToken: String; let refreshToken: String?; let idToken: String?
        let scopes: [String]; let expiresIn: TimeInterval
    }
    private func exchange(_ form: [String: String]) async throws -> Tokens {
        let (data, status) = try await http.send(Self.formRequest(Self.tokenURL, form))
        guard status == 200 else { throw SIWCError.remote("oauth_\(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let type = json["token_type"] as? String, type.lowercased() == "bearer",
              let expiry = json["expires_in"] as? Double, expiry > 0,
              let scope = json["scope"] as? String else { throw SIWCError.invalidIdentity }
        return Tokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
            idToken: json["id_token"] as? String, scopes: scope.split(separator: " ").map(String.init), expiresIn: expiry)
    }
    static func formRequest(_ url: URL, _ params: [String: String]) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(params.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }
    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, status) = try await http.send(URLRequest(url: url))
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SIWCError.invalidIdentity }
        return json
    }
    private func validateIDToken(_ token: String?, clientID: String, nonce: String?) async throws -> (subject: String, email: String?) {
        guard let token else { throw SIWCError.invalidIdentity }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, let headerData = Data(base64URL: pieces[0]), let payloadData = Data(base64URL: pieces[1]),
              let signature = Data(base64URL: pieces[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["crit"] == nil,
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw SIWCError.invalidIdentity }
        let discovery = try await getJSON(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        guard discovery["issuer"] as? String == "https://auth.openai.com", let uri = discovery["jwks_uri"] as? String,
              let url = URL(string: uri), url.scheme == "https", url.host == "auth.openai.com" else { throw SIWCError.invalidIdentity }
        let jwks = try await getJSON(url)
        guard let keys = jwks["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              (key["alg"] == nil || key["alg"] as? String == "RS256"),
              (key["use"] == nil || key["use"] as? String == "sig"),
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else { throw SIWCError.invalidIdentity }
        let keyData = Self.der(0x30, Self.derInteger(modulus) + Self.derInteger(exponent))
        guard let publicKey = SecKeyCreateWithData(keyData as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil),
              payload["iss"] as? String == "https://auth.openai.com",
              (payload["aud"] as? String == clientID || (payload["aud"] as? [String])?.contains(clientID) == true),
              let exp = payload["exp"] as? Double, exp > Date().timeIntervalSince1970,
              let subject = payload["sub"] as? String, !subject.isEmpty,
              nonce == nil || payload["nonce"] as? String == nonce else { throw SIWCError.invalidIdentity }
        if let aud = payload["aud"] as? [String], aud.count > 1, payload["azp"] as? String != clientID { throw SIWCError.invalidIdentity }
        if let nbf = payload["nbf"] as? Double, nbf > Date().timeIntervalSince1970 { throw SIWCError.invalidIdentity }
        return (subject, payload["email"] as? String)
    }
    static func derInteger(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
        return der(0x02, bytes)
    }
    static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var count = bytes.count, length = Data()
        if count < 128 { length.append(UInt8(count)) }
        else {
            while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag]) + length + bytes
    }
}
public struct SIWCAccountSummary: Sendable, Identifiable {
    public let id: String; public let label: String; public let clientID: String
    public let active: Bool; public let authorized: Bool
}
extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL string: String) {
        let encoded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    }
}

public struct SIWCModelSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let accountID: String
    public let details: JSONObject
    public var detailsText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(details) else { return "Model details unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
}
