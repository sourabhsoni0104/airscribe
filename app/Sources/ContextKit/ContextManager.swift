import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

struct ContextCaptureOptions: Sendable {
    let includeClipboard: Bool
    let includeScreenText: Bool
    let excludedBundleIdentifiers: Set<String>
}

struct ContextSnapshot: Sendable, Equatable {
    let bundleIdentifier: String?
    let applicationName: String?
    let windowTitle: String?
    let focusedText: String?
    let clipboardText: String?
    let screenText: String?

    static let empty = ContextSnapshot(
        bundleIdentifier: nil,
        applicationName: nil,
        windowTitle: nil,
        focusedText: nil,
        clipboardText: nil,
        screenText: nil
    )

    var isEmpty: Bool {
        [applicationName, windowTitle, focusedText, clipboardText, screenText]
            .allSatisfy { $0?.isEmpty != false }
    }

    var promptContext: String {
        var sections: [String] = []
        if let applicationName { sections.append("Active app: \(applicationName)") }
        if let windowTitle { sections.append("Window: \(windowTitle)") }
        if let focusedText { sections.append("Focused text: \(focusedText)") }
        if let clipboardText { sections.append("Clipboard: \(clipboardText)") }
        if let screenText { sections.append("Visible text: \(screenText)") }
        return sections.joined(separator: "\n")
    }
}

@MainActor
final class ContextManager {
    func capture(options: ContextCaptureOptions) async -> ContextSnapshot {
        guard !IsSecureEventInputEnabled(),
              let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              !options.excludedBundleIdentifiers.contains(bundleIdentifier) else {
            return .empty
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedElement = copiedElement(appElement, attribute: kAXFocusedUIElementAttribute)
        let secureField = SecureInputGuard.isSecure(focusedElement)
        let window = copiedElement(appElement, attribute: kAXFocusedWindowAttribute)
        let windowTitle = copiedString(window, attribute: kAXTitleAttribute)
        let focusedText = secureField ? nil : capturedFocusedText(focusedElement)
        let clipboardText = options.includeClipboard && !secureField
            ? limited(NSPasteboard.general.string(forType: .string), to: 2_000)
            : nil

        var screenText: String?
        if options.includeScreenText,
           !secureField,
           let frame = copiedFrame(window),
           frame.width > 10,
           frame.height > 10,
           let image = try? await captureImage(in: frame) {
            screenText = limited(Self.recognizeText(in: image), to: 3_000)
        }

        return ContextSnapshot(
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName,
            windowTitle: limited(windowTitle, to: 300),
            focusedText: focusedText,
            clipboardText: clipboardText,
            screenText: screenText
        )
    }

    private func capturedFocusedText(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        if let selected = copiedString(element, attribute: kAXSelectedTextAttribute), !selected.isEmpty {
            return limited(selected, to: 2_000)
        }
        return limited(copiedString(element, attribute: kAXValueAttribute), to: 2_000)
    }

    private func copiedElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copiedString(_ element: AXUIElement?, attribute: String) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copiedFrame(_ element: AXUIElement?) -> CGRect? {
        guard let element,
              let position = copiedAXValue(element, attribute: kAXPositionAttribute, type: .cgPoint),
              let size = copiedAXValue(element, attribute: kAXSizeAttribute, type: .cgSize) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func copiedAXValue(
        _ element: AXUIElement,
        attribute: String,
        type: AXValueType
    ) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    private func captureImage(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ContextCaptureError.screenshotUnavailable)
                }
            }
        }
    }

    nonisolated private static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func limited(_ value: String?, to maximumLength: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumLength))
    }
}

private enum ContextCaptureError: Error {
    case screenshotUnavailable
}
