import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

struct TextInserter: Sendable {
    struct PasteboardSnapshot: @unchecked Sendable {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    struct InsertionHandle: @unchecked Sendable {
        fileprivate let element: AXUIElement?
        fileprivate let processIdentifier: pid_t
        fileprivate let insertionLocation: Int?
        let insertedText: String
        fileprivate let prefix: String?
        fileprivate let suffix: String?
    }

    @MainActor
    @discardableResult
    func insert(_ text: String) throws -> InsertionHandle {
        guard AXIsProcessTrusted() else { throw AirScribeError.accessibilityPermissionDenied }

        let element = focusedElement()
        guard !SecureInputGuard.isSecure(element) else { throw AirScribeError.secureInputActive }
        var processIdentifier: pid_t = 0
        if let element { AXUIElementGetPid(element, &processIdentifier) }
        let selection = element.flatMap(selectedRange)
        let insertionLocation = selection.map(\.location)
        let originalValue = element.flatMap(stringValue)
        let boundaries = originalValue.flatMap { value -> (String, String)? in
            guard let selection else { return nil }
            let source = value as NSString
            guard selection.location >= 0,
                  selection.length >= 0,
                  NSMaxRange(NSRange(location: selection.location, length: selection.length)) <= source.length else {
                return nil
            }
            return (
                source.substring(to: selection.location),
                source.substring(from: selection.location + selection.length)
            )
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertionChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            restorePasteboard(snapshot, to: pasteboard)
            throw AirScribeError.accessibilityPermissionDenied
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            // Do not overwrite a clipboard change the user made while insertion was in flight.
            if pasteboard.changeCount == insertionChangeCount {
                restorePasteboard(snapshot, to: pasteboard)
            }
        }
        return InsertionHandle(
            element: element,
            processIdentifier: processIdentifier,
            insertionLocation: insertionLocation,
            insertedText: text,
            prefix: boundaries?.0,
            suffix: boundaries?.1
        )
    }

    @MainActor
    func replace(_ handle: InsertionHandle, with replacement: String) -> InsertionHandle? {
        guard replacement != handle.insertedText,
              AXIsProcessTrusted(),
              let element = handle.element,
              let current = focusedElement(),
              !SecureInputGuard.isSecure(current),
              CFEqual(element, current) else { return nil }

        var currentProcessIdentifier: pid_t = 0
        AXUIElementGetPid(current, &currentProcessIdentifier)
        guard currentProcessIdentifier == handle.processIdentifier,
              let location = handle.insertionLocation,
              let value = stringValue(of: current) else { return nil }

        let insertedLength = (handle.insertedText as NSString).length
        let targetRange = NSRange(location: location, length: insertedLength)
        let currentNSString = value as NSString
        guard NSMaxRange(targetRange) <= currentNSString.length,
              currentNSString.substring(with: targetRange) == handle.insertedText else { return nil }

        var range = CFRange(location: location, length: insertedLength)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(current, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
            return nil
        }
        return InsertionHandle(
            element: handle.element,
            processIdentifier: handle.processIdentifier,
            insertionLocation: handle.insertionLocation,
            insertedText: replacement,
            prefix: handle.prefix,
            suffix: handle.suffix
        )
    }

    @MainActor
    func correctedText(for handle: InsertionHandle) -> String? {
        guard AXIsProcessTrusted(),
              let element = handle.element,
              let current = focusedElement(),
              !SecureInputGuard.isSecure(current),
              CFEqual(element, current),
              let prefix = handle.prefix,
              let suffix = handle.suffix,
              let value = stringValue(of: current) else { return nil }

        var currentProcessIdentifier: pid_t = 0
        AXUIElementGetPid(current, &currentProcessIdentifier)
        guard currentProcessIdentifier == handle.processIdentifier else { return nil }

        let valueNSString = value as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        guard valueNSString.length >= prefixLength + suffixLength,
              valueNSString.substring(to: prefixLength) == prefix,
              valueNSString.substring(from: valueNSString.length - suffixLength) == suffix else { return nil }
        let observed = valueNSString.substring(
            with: NSRange(
                location: prefixLength,
                length: valueNSString.length - prefixLength - suffixLength
            )
        )
        return observed == handle.insertedText ? nil : observed
    }

    @MainActor
    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    @MainActor
    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        return (value as! AXUIElement)
    }

    @MainActor
    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    @MainActor
    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
