import Foundation

enum LocalGatewayAuthorization {
    static let expectedHeader = "x-api-key"

    static func providedToken(from headers: [String: String]) -> String? {
        if let token = headers[expectedHeader], !token.isEmpty {
            return token
        }

        guard let authorization = headers["authorization"], !authorization.isEmpty else {
            return nil
        }

        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            return nil
        }
        return parts[1]
    }

    static func isAuthorized(headers: [String: String], expectedToken: String) -> Bool {
        providedToken(from: headers) == expectedToken
    }

    /// Returns last-6 of a token for diagnostic logging, or a sentinel describing
    /// why the value is missing. Never returns the full token.
    static func tokenSuffix(_ token: String?) -> String {
        guard let token else { return "<missing>" }
        if token.isEmpty { return "<empty>" }
        if token.count <= 6 { return "<short>" }
        return String(token.suffix(6))
    }

    static func unauthorizedResponse(
        providedSuffix: String,
        expectedSuffix: String
    ) -> HTTPResponse {
        let envelope = AnthropicErrorEnvelope(
            error: AnthropicErrorBody(
                type: "authentication_error",
                message: "Local gateway token mismatch: client x-api-key suffix \(providedSuffix) does not match gateway token suffix \(expectedSuffix). Update the client's ANTHROPIC_AUTH_TOKEN to the value shown in the Claudex app."
            )
        )
        return try! HTTPResponse.json(
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            value: envelope
        )
    }
}
