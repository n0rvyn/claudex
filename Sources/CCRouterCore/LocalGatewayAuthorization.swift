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

    static func unauthorizedResponse() -> HTTPResponse {
        let envelope = AnthropicErrorEnvelope(
            error: AnthropicErrorBody(
                type: "authentication_error",
                message: "Invalid local gateway token. Claude Code must send ANTHROPIC_AUTH_TOKEN through x-api-key."
            )
        )
        return try! HTTPResponse.json(
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            value: envelope
        )
    }
}
