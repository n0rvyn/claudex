import CryptoKit
import Foundation
@testable import CCRouterCore
import Testing

struct CL100KEncoderReferenceTests {
    @Test
    func bundledResourceHashMatchesPinnedSHA256() throws {
        let data = try CL100KEncoder.bundledResourceData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #expect(digest == "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7")
    }

    @Test
    func encoderMatchesCommittedFixtureCases() throws {
        let encoder = try CL100KEncoder.shared()
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "cl100k_reference_cases", withExtension: "json")
        )
        let data = try Data(contentsOf: fixtureURL)
        let cases = try JSONDecoder().decode([FixtureRow].self, from: data)

        for fixture in cases {
            let tokenIDs = try encoder.encode(fixture.input)
            #expect(tokenIDs == fixture.token_ids)
            #expect(tokenIDs.count == fixture.count)
        }
    }

    private struct FixtureRow: Codable, Sendable {
        let input: String
        let token_ids: [Int]
        let count: Int
    }
}
