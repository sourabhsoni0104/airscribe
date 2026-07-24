import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum SecureInputGuard {
    static func isSecure(_ element: AXUIElement?) -> Bool {
        IsSecureEventInputEnabled() || element.map(isSecureElement) == true
    }

    static func isSecureRole(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }

    private static func isSecureElement(_ element: AXUIElement) -> Bool {
        isSecureRole(
            role: copiedString(element, attribute: kAXRoleAttribute),
            subrole: copiedString(element, attribute: kAXSubroleAttribute)
        )
    }

    private static func copiedString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
