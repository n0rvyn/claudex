import Testing
@testable import CCRouterCore

struct LocalGatewayAuthorizationTests {
    @Test
    func acceptsExactXAPIKey() {
        #expect(
            LocalGatewayAuthorization.isAuthorized(
                headers: ["x-api-key": "token-123"],
                expectedToken: "token-123"
            )
        )
    }

    @Test
    func acceptsBearerTokenFallback() {
        #expect(
            LocalGatewayAuthorization.isAuthorized(
                headers: ["authorization": "Bearer token-123"],
                expectedToken: "token-123"
            )
        )
    }

    @Test
    func rejectsMismatchedToken() {
        #expect(
            !LocalGatewayAuthorization.isAuthorized(
                headers: ["x-api-key": "wrong-token"],
                expectedToken: "token-123"
            )
        )
    }
}
