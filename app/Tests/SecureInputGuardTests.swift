import XCTest
@testable import AirScribe

final class SecureInputGuardTests: XCTestCase {
    func testRecognizesSecureAccessibilitySubrole() {
        XCTAssertTrue(SecureInputGuard.isSecureRole(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    func testRecognizesPasswordRolesCaseInsensitively() {
        XCTAssertTrue(SecureInputGuard.isSecureRole(role: "passwordField", subrole: nil))
    }

    func testAllowsOrdinaryTextFields() {
        XCTAssertFalse(SecureInputGuard.isSecureRole(role: "AXTextArea", subrole: "AXStandardTextField"))
    }
}
