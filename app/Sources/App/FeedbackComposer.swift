import AppKit
import Foundation

/// Opens the user's mail client with a feedback message addressed to the author.
///
/// The details people always get asked for anyway (app version, macOS version,
/// hardware, which engine ran) are filled in, so a report arrives useful on the
/// first try. Nothing is collected or sent anywhere by AirScribe itself: this only
/// hands a prefilled draft to the mail client, and the user decides whether to
/// send it.
enum FeedbackComposer {
    /// Change this to redirect feedback.
    static let recipient = "motivatedguy8@gmail.com"

    static func compose(modelState: String, engine: String?) {
        let subject = "AirScribe feedback (\(appVersion))"
        let body = """


        ---
        The lines below help with diagnosis. Delete anything you would rather not send.

        AirScribe: \(appVersion)
        macOS: \(systemVersion)
        Mac: \(hardwareModel)
        Models: \(modelState)
        Last engine: \(engine ?? "none yet")
        """

        guard let url = mailURL(subject: subject, body: body) else { return }
        // If no mail client is configured, macOS does nothing with a mailto URL,
        // so fall back to putting the address on the clipboard.
        if !NSWorkspace.shared.open(url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recipient, forType: .string)
        }
    }

    static func mailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}
