import Foundation
import Testing
@testable import CCRouterCore

struct GatewayBoundaryTests {
    @Test func rejectsNonLoopbackListener() throws {
        let config = RouterConfiguration(environment: ["CC_ROUTER_HOST": "0.0.0.0"])
        let server = LocalHTTPServer(configuration: config) { _ in HTTPResponse(statusCode: 200, reasonPhrase: "OK") }
        #expect(throws: (any Error).self) { try server.start() }
    }
    @Test func authErrorContainsNoCredentialFragments() throws {
        let response = LocalGatewayAuthorization.unauthorizedResponse(providedSuffix: "SECRET", expectedSuffix: "OTHERSECRET")
        let text = String(data: try #require(response.bodyData), encoding: .utf8)!
        #expect(!text.contains("SECRET"))
        #expect(response.statusCode == 401)
    }
}
