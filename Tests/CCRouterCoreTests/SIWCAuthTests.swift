import Foundation
import Testing
@testable import CCRouterCore

private actor OAuthFixtureHTTP: SIWCHTTP {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let json = #"{"access_token":"fixture-new","refresh_token":"fixture-rotated","token_type":"Bearer","expires_in":3600,"scope":"chatgpt.tokens.use.direct resource.invoke"}"#
        return (Data(json.utf8), 200)
    }
    var count: Int { requests.count }
    func firstBody() -> String { String(data: requests.first?.httpBody ?? Data(), encoding: .utf8)! }
}
struct SIWCAuthTests {
    private func store() -> SIWCStore { SIWCStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-test-" + UUID().uuidString)) }
    @Test func newRegistrationIsAppOwnedAndUsesS256() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let http = OAuthFixtureHTTP(), auth = SIWCAuth(store: store, http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        let params = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value!) })
        #expect(values["client_id"] == "dynamic_agent_client")
        #expect(values["agent_name_hint"] == "Claudex")
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"] != attempt.verifier)
        #expect(values["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        #expect(await http.count == 0)
        let next = try await auth.begin(redirectURI: attempt.redirectURI)
        let nextParams = URLComponents(url: next.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(nextParams.first { $0.name == "ext_agent_host_id" }?.value == values["ext_agent_host_id"])
        #expect(next.state != attempt.state)
        #expect(next.nonce != attempt.nonce)
    }
    @Test func callbackStateAndClientMismatchNeverTransmitCode() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let http = OAuthFixtureHTTP(), auth = SIWCAuth(store: store, http: http)
        _ = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        await #expect(throws: SIWCError.self) {
            try await auth.complete(callback: URL(string: "http://127.0.0.1:19000/auth/callback?state=wrong&code=fixture&client_id=oaiapp_fixture")!)
        }
        #expect(await http.count == 0)
        #expect(try await auth.accounts().isEmpty)
    }
    @Test func refusesNonLiteralCallback() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let auth = SIWCAuth(store: store, http: OAuthFixtureHTTP())
        await #expect(throws: SIWCError.self) { _ = try await auth.begin(redirectURI: "http://localhost:19000/auth/callback") }
    }
    @Test func deniedConsentIsSingleUse() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let http = OAuthFixtureHTTP(), auth = SIWCAuth(store: store, http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        let callback = URL(string: attempt.redirectURI + "?state=" + attempt.state + "&error=access_denied")!
        await #expect(throws: SIWCError.self) { try await auth.complete(callback: callback) }
        await #expect(throws: SIWCError.self) { try await auth.complete(callback: callback) }
        #expect(await http.count == 0)
    }
    @Test func missingIDTokenCannotBecomeActive() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let http = OAuthFixtureHTTP(), auth = SIWCAuth(store: store, http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        let callback = URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=fixture&client_id=oaiapp_fixture")!
        await #expect(throws: SIWCError.self) { try await auth.complete(callback: callback) }
        #expect(try await auth.accounts().isEmpty)
        #expect(await http.firstBody().contains("client_id=oaiapp_fixture"))
        #expect(await http.firstBody().contains("code_verifier="))
    }
    @Test func refreshIsSerializedAcrossAuthInstancesAndPreservesRegistration() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let account = SIWCAccount(clientID: "oaiapp_fixture", subject: "fixture-sub", email: nil,
            accessToken: "fixture-old", refreshToken: "fixture-refresh", idToken: nil,
            scopes: ["chatgpt.tokens.use.direct", "resource.invoke"], expiresAt: .distantPast)
        let fd = try await store.acquire()
        try store.write(SIWCState(accounts: [account], activeID: account.id)); store.release(fd)
        let http = OAuthFixtureHTTP()
        let first = SIWCAuth(store: store, http: http), second = SIWCAuth(store: store, http: http)
        async let a = first.loadCurrent()
        async let b = second.loadCurrent()
        let result = try await (a, b)
        #expect(result.0.accessToken == "fixture-new")
        #expect(result.1.accessToken == "fixture-new")
        #expect(await http.count == 1)
        let body = await http.firstBody()
        #expect(body.contains("client_id=oaiapp_fixture"))
        #expect(body.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
        #expect(!body.contains("scope="))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("accounts.json").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func unsafeCredentialPermissionsFailClosed() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let fd = try await store.acquire(); try store.write(SIWCState()); store.release(fd)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.directory.appendingPathComponent("accounts.json").path)
        let auth = SIWCAuth(store: store, http: OAuthFixtureHTTP())
        await #expect(throws: SIWCError.self) { _ = try await auth.loadCurrent() }
    }
}
