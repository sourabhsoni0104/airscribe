import XCTest
@testable import AirScribe

final class CloudPolishRequestTests: XCTestCase {
    func testTokenBudgetScalesWithDictationLength() {
        let short = CloudTextEnhancer.outputTokenBudget(for: "Send it now.")
        XCTAssertEqual(short, 1_024, "Short dictation keeps the floor budget")

        let long = CloudTextEnhancer.outputTokenBudget(
            for: String(repeating: "word ", count: 4_000)
        )
        XCTAssertGreaterThan(long, 1_024, "A long dictation needs more than the old fixed budget")
        XCTAssertLessThanOrEqual(long, 16_384)
    }

    func testKnownProviderHostsAreRecognisedIncludingSubdomains() {
        XCTAssertTrue(CloudTextEnhancer.isKnownProviderHost("api.openai.com"))
        XCTAssertTrue(CloudTextEnhancer.isKnownProviderHost("API.OpenAI.com"))
        XCTAssertTrue(CloudTextEnhancer.isKnownProviderHost("eu.api.openai.com"))
        XCTAssertFalse(CloudTextEnhancer.isKnownProviderHost("api.openai.com.attacker.test"))
        XCTAssertFalse(CloudTextEnhancer.isKnownProviderHost("example.com"))
        XCTAssertFalse(CloudTextEnhancer.isKnownProviderHost(nil))
    }

    func testUnknownHostIsRefusedUntilAcknowledged() async {
        let enhancer = CloudTextEnhancer()
        let endpoint = URL(string: "https://example.com/v1/responses")!
        do {
            _ = try await enhancer.enhance(
                "Hello",
                instruction: "",
                configuration: CloudPolishConfiguration(
                    endpoint: endpoint,
                    model: "test",
                    apiKey: "not-a-real-key"
                )
            )
            XCTFail("An unrecognised host must not receive the API key")
        } catch let CloudPolishError.unconfirmedEndpointHost(host) {
            XCTAssertEqual(host, "example.com")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialBearingEndpointIsStillRejectedFirst() async {
        let enhancer = CloudTextEnhancer()
        do {
            _ = try await enhancer.enhance(
                "Hello",
                instruction: "",
                configuration: CloudPolishConfiguration(
                    endpoint: URL(string: "https://user:password@api.openai.com/v1/responses")!,
                    model: "test",
                    apiKey: "not-a-real-key",
                    acknowledgedHost: "api.openai.com"
                )
            )
            XCTFail("A URL containing credentials must be rejected before any network request")
        } catch CloudPolishError.insecureEndpoint {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
