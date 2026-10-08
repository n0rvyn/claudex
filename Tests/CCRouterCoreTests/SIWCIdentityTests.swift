import Foundation
import Security
import Testing
@testable import CCRouterCore

private actor IdentityHTTP: SIWCHTTP {
    var token = ""
    var pauseExchange = false
    var exchangeStarted = false
    var gate: CheckedContinuation<Void, Never>?
    func pause() { pauseExchange = true }
    func started() -> Bool { exchangeStarted }
    func resume() { gate?.resume(); gate = nil }

    let jwks: Data
    init(jwks: Data) { self.jwks = jwks }
    func set(_ token: String) { self.token = token }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path == "/.well-known/openid-configuration" {
            return (Data(#"{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/fixture-jwks"}"#.utf8), 200)
        }
        if request.url?.path == "/fixture-jwks" { return (jwks, 200) }
        if pauseExchange {
            exchangeStarted = true
            await withCheckedContinuation { gate = $0 }
        }
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "fixture-access", "refresh_token": "fixture-refresh",
            "id_token": token, "token_type": "Bearer", "scope": "chatgpt.tokens.use.direct resource.invoke", "expires_in": 3600])
        return (data, 200)
    }
}
private struct FixtureRSA {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let raw = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 0
        func tlv(_ bytes: Data, _ offset: inout Int) -> Data {
            offset += 1
            var count = Int(bytes[offset]); offset += 1
            if count & 128 != 0 {
                let digits = count & 127; count = 0
                for _ in 0..<digits { count = count * 256 + Int(bytes[offset]); offset += 1 }
            }
            let result = bytes.subdata(in: offset..<(offset + count)); offset += count; return result
        }
        let sequence = tlv(raw, &offset); offset = 0
        let n = Data(tlv(sequence, &offset).drop(while: { $0 == 0 })), e = tlv(sequence, &offset)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture-key", "alg": "RS256", "n": n.base64URL, "e": e.base64URL]]])
    }
    func token(nonce: String, overrides: [String: Any] = [:]) throws -> String {
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_fixture", "sub": "fixture-subject",
            "email": "fixture@example.invalid", "nonce": nonce, "exp": Date().addingTimeInterval(600).timeIntervalSince1970]
        claims.merge(overrides) { _, new in new }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture-key"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let message = header + "." + payload
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
        return message + "." + signature.base64URL
    }
}
struct SIWCIdentityTests {
    @Test func verifiedIdentityIsTheOnlyPathToActiveRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rsa = try FixtureRSA(), http = IdentityHTTP(jwks: rsa.jwks)
        let auth = SIWCAuth(store: SIWCStore(directory: directory), http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        await http.set(try rsa.token(nonce: attempt.nonce))
        try await auth.complete(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=fixture&client_id=oaiapp_fixture")!)
        let accounts = try await auth.accounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.active == true)
        #expect(accounts.first?.id == "oaiapp_fixture:fixture-subject")
        let credentials = try await auth.loadCurrent()
        #expect(credentials.accessToken == "fixture-access")
    }
    @Test func signedButInvalidClaimsCannotActivateAccount() async throws {
        let rsa = try FixtureRSA()
        let variants: [[String: Any]] = [["iss": "https://attacker.invalid"], ["aud": "another-client"],
            ["exp": 0], ["nonce": "another-attempt"], ["sub": ""]]
        for overrides in variants {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-negative-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let http = IdentityHTTP(jwks: rsa.jwks), auth = SIWCAuth(store: SIWCStore(directory: directory), http: http)
            let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
            await http.set(try rsa.token(nonce: attempt.nonce, overrides: overrides))
            await #expect(throws: SIWCError.self) {
                try await auth.complete(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=fixture&client_id=oaiapp_fixture")!)
            }
            let accounts = try await auth.accounts()
            #expect(accounts.isEmpty)
        }
    }
    @Test func tamperedSignatureCannotActivateAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-tampered-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rsa = try FixtureRSA(), http = IdentityHTTP(jwks: rsa.jwks)
        let auth = SIWCAuth(store: SIWCStore(directory: directory), http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        let token = try rsa.token(nonce: attempt.nonce)
        var parts = token.components(separatedBy: ".")
        parts[2] = Data(repeating: 0, count: 256).base64URL
        await http.set(parts.joined(separator: "."))
        await #expect(throws: SIWCError.self) {
            try await auth.complete(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=fixture&client_id=oaiapp_fixture")!)
        }
        #expect(try await auth.accounts().isEmpty)
    }
    @Test func cancelledExchangeCannotActivateRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-cancelled-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rsa = try FixtureRSA(), http = IdentityHTTP(jwks: rsa.jwks)
        let auth = SIWCAuth(store: SIWCStore(directory: directory), http: http)
        let attempt = try await auth.begin(redirectURI: "http://127.0.0.1:19000/auth/callback")
        await http.set(try rsa.token(nonce: attempt.nonce)); await http.pause()
        let task = Task { try await auth.complete(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=fixture&client_id=oaiapp_fixture")!) }
        while !(await http.started()) { await Task.yield() }
        await auth.cancelSignIn(); await http.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await auth.accounts().isEmpty)
    }

}
