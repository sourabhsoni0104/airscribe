import Foundation
import Security

/// Reports how this copy of AirScribe is signed.
///
/// macOS binds an Accessibility grant to the app's designated requirement. When
/// a build carries no stable signing identity, that requirement is just the
/// binary's cdhash, so the grant stops applying the moment the app is rebuilt or
/// updated: `AXIsProcessTrusted()` returns false while System Settings still
/// shows the switch turned on, because that row is keyed by path rather than by
/// the binary it authorised.
///
/// Knowing which situation we are in lets the app explain the real fix instead of
/// telling the user to toggle a switch that cannot help.
struct CodeSignatureInfo: Sendable, Equatable {
    /// The signing identifier, which should match the bundle identifier.
    let identifier: String?
    /// True when the signature is ad-hoc, meaning there is no certificate to
    /// anchor the requirement to.
    let isAdHoc: Bool
    /// True for the weakest form, applied by the linker when a build is made
    /// with code signing disabled. These use the executable name as the
    /// identifier, which also breaks `tccutil reset`.
    let isLinkerSigned: Bool

    /// Whether permissions granted to this build will survive an update.
    var grantsPersistAcrossUpdates: Bool { !isAdHoc && !isLinkerSigned }

    static let unknown = CodeSignatureInfo(identifier: nil, isAdHoc: true, isLinkerSigned: true)

    /// Reads the signature of the running process.
    static func current() -> CodeSignatureInfo {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return .unknown
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return .unknown
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let details = information as NSDictionary? else {
            return .unknown
        }

        let identifier = details[kSecCodeInfoIdentifier as String] as? String
        let flags = (details[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        // Values from cs_blobs.h: adhoc is 0x2, linkerSigned is 0x20000.
        let adHoc = flags & 0x2 != 0
        let linkerSigned = flags & 0x20000 != 0
        return CodeSignatureInfo(
            identifier: identifier,
            isAdHoc: adHoc,
            isLinkerSigned: linkerSigned
        )
    }

    /// One line explaining the consequence, or nil when the build is fine.
    var permissionWarning: String? {
        guard !grantsPersistAcrossUpdates else { return nil }
        return "This build is not signed with a stable identity, so macOS drops its Accessibility permission whenever AirScribe is updated. Signing the app fixes this for good."
    }
}
