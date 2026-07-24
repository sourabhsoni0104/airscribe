import XCTest
@testable import AirScribe

/// Covers the case where macOS lists AirScribe as allowed but no longer trusts
/// the binary, which happens whenever an unsigned build is updated.
@MainActor
final class AccessibilityGrantStalenessTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AirScribeTests.Permissions.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAFreshInstallIsNotReportedAsStale() {
        let manager = PermissionManager(defaults: defaults)
        // Never trusted, so a missing grant just means the user has not allowed it.
        if !manager.accessibilityGranted {
            XCTAssertFalse(manager.accessibilityGrantIsStale)
        }
    }

    func testHavingBeenTrustedBeforeMakesALostGrantStale() {
        defaults.set(true, forKey: "accessibilityWasGrantedPreviously")
        let manager = PermissionManager(defaults: defaults)
        // On a machine where the test process is not trusted, the previously
        // recorded grant is the signal that the record no longer matches.
        if !manager.accessibilityGranted {
            XCTAssertTrue(manager.accessibilityGrantIsStale)
            let advice = manager.accessibilityAdvice
            XCTAssertNotNil(advice)
            XCTAssertTrue(
                advice?.contains("minus") == true,
                "Advice must tell the user to remove the entry, not toggle it"
            )
        }
    }

    func testAdviceExplainsWhyTogglingWillNotWork() throws {
        defaults.set(true, forKey: "accessibilityWasGrantedPreviously")
        let manager = PermissionManager(defaults: defaults)
        guard !manager.accessibilityGranted else {
            throw XCTSkip("This process is trusted, so staleness cannot be exercised")
        }
        XCTAssertTrue(manager.accessibilityAdvice?.contains("will not fix it") == true)
    }

    func testUnsignedBuildsAreReportedAsNotPersisting() {
        // The test host is built with code signing disabled, so it stands in for
        // exactly the situation users hit with an unsigned release.
        let signature = CodeSignatureInfo.current()
        if signature.isAdHoc || signature.isLinkerSigned {
            XCTAssertFalse(signature.grantsPersistAcrossUpdates)
            XCTAssertNotNil(signature.permissionWarning)
        } else {
            XCTAssertTrue(signature.grantsPersistAcrossUpdates)
            XCTAssertNil(signature.permissionWarning)
        }
    }

    func testSignatureReadingNeverReturnsGarbage() {
        let signature = CodeSignatureInfo.current()
        if let identifier = signature.identifier {
            XCTAssertFalse(identifier.isEmpty)
        }
    }
}
