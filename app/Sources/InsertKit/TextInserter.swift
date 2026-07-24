import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

struct TextInserter: Sendable {
    enum InsertionResult: Sendable {
        case inserted(InsertionHandle)
        case copiedToClipboard

        var handle: InsertionHandle? {
            switch self {
            case let .inserted(handle):
                return handle
            case .copiedToClipboard:
                return nil
            }
        }

        var wasCopiedToClipboard: Bool {
            if case .copiedToClipboard = self {
                return true
            }
            return false
        }
    }

    struct PasteboardSnapshot: @unchecked Sendable {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    struct InsertionHandle: @unchecked Sendable {
        let id: UUID
        fileprivate let element: AXUIElement?
        fileprivate let processIdentifier: pid_t
        fileprivate let insertionLocation: Int?
        let insertedText: String
        fileprivate let prefix: String?
        fileprivate let suffix: String?
        fileprivate let beforeAnchor: String
        fileprivate let afterAnchor: String
        fileprivate let unaffectedCharacterCount: Int?
    }

    @MainActor
    @discardableResult
    func insert(_ text: String) async throws -> InsertionResult {
        // Clipboard fallback must remain available even when macOS has stale or
        // missing Accessibility authorization. Direct insertion still requires it.
        guard !SecureInputGuard.isSecure(nil) else { throw AirScribeError.secureInputActive }
        guard AXIsProcessTrusted() else {
            try copyToClipboard(text)
            return .copiedToClipboard
        }

        let element = focusedElement()
        guard !SecureInputGuard.isSecure(element) else { throw AirScribeError.secureInputActive }
        guard let element, isEditableTextElement(element) else {
            try copyToClipboard(text)
            return .copiedToClipboard
        }

        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        let selection = selectedRange(of: element)
        let insertionLocation = selection.map(\.location)
        let originalValue = stringValue(of: element)
        let originalCharacterCount = originalValue.map { ($0 as NSString).length }
            ?? characterCount(of: element)
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
        let anchors = contextAnchors(
            for: element,
            selection: selection,
            boundaries: boundaries
        )
        let handle = InsertionHandle(
            id: UUID(),
            element: element,
            processIdentifier: processIdentifier,
            insertionLocation: insertionLocation,
            insertedText: text,
            prefix: boundaries?.0,
            suffix: boundaries?.1,
            beforeAnchor: anchors.before,
            afterAnchor: anchors.after,
            unaffectedCharacterCount: originalCharacterCount.map {
                max(0, $0 - (selection?.length ?? 0))
            }
        )

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              pasteboard.string(forType: .string) == text else {
            restorePasteboard(snapshot, to: pasteboard)
            throw AirScribeError.clipboardCopyFailed
        }
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

        // Accessibility updates arrive at different speeds in native and web
        // editors. Only report "Inserted" after observing the new text.
        for delay in [70, 100, 140, 190] {
            try? await Task.sleep(for: .milliseconds(delay))
            if insertionWasObserved(handle) {
                if pasteboard.changeCount == insertionChangeCount {
                    restorePasteboard(snapshot, to: pasteboard)
                }
                return .inserted(handle)
            }
        }

        // If insertion cannot be verified, leave the actual transcript on the
        // clipboard and report the safe fallback instead of a false success.
        try copyToClipboard(text)
        return .copiedToClipboard
    }

    @MainActor
    func copyToClipboard(_ text: String) throws {
        guard Self.write(text, to: .general) else {
            throw AirScribeError.clipboardCopyFailed
        }
    }

    @MainActor
    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
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
            id: handle.id,
            element: handle.element,
            processIdentifier: handle.processIdentifier,
            insertionLocation: handle.insertionLocation,
            insertedText: replacement,
            prefix: handle.prefix,
            suffix: handle.suffix,
            beforeAnchor: handle.beforeAnchor,
            afterAnchor: handle.afterAnchor,
            unaffectedCharacterCount: handle.unaffectedCharacterCount
        )
    }

    @MainActor
    func correctedText(for handle: InsertionHandle) -> String? {
        guard AXIsProcessTrusted(),
              let element = handle.element,
              !SecureInputGuard.isSecure(element) else { return nil }
        if let current = focusedElement(), SecureInputGuard.isSecure(current) {
            return nil
        }

        var currentProcessIdentifier: pid_t = 0
        AXUIElementGetPid(element, &currentProcessIdentifier)
        guard currentProcessIdentifier == handle.processIdentifier else { return nil }

        if let prefix = handle.prefix,
           let suffix = handle.suffix,
           let value = stringValue(of: element) {
            let valueNSString = value as NSString
            let prefixLength = (prefix as NSString).length
            let suffixLength = (suffix as NSString).length
            if valueNSString.length >= prefixLength + suffixLength,
               valueNSString.substring(to: prefixLength) == prefix,
               valueNSString.substring(from: valueNSString.length - suffixLength) == suffix {
                let observed = valueNSString.substring(
                    with: NSRange(
                        location: prefixLength,
                        length: valueNSString.length - prefixLength - suffixLength
                    )
                )
                return observed == handle.insertedText ? nil : observed
            }
        }

        guard let insertionLocation = handle.insertionLocation,
              let snapshot = correctionSnapshot(
                  for: element,
                  insertionLocation: insertionLocation,
                  insertedLength: (handle.insertedText as NSString).length,
                  beforeAnchor: handle.beforeAnchor,
                  afterAnchor: handle.afterAnchor,
                  unaffectedCharacterCount: handle.unaffectedCharacterCount
              ),
              let observed = Self.textBetweenAnchors(
                  in: snapshot.text,
                  insertionOffset: insertionLocation - snapshot.baseLocation,
                  beforeAnchor: handle.beforeAnchor,
                  afterAnchor: handle.afterAnchor,
                  inferredEndOffset: snapshot.inferredEndLocation.map {
                      $0 - snapshot.baseLocation
                  },
                  cursorOffset: snapshot.cursorLocation.map { $0 - snapshot.baseLocation }
              ) else {
            return nil
        }
        return observed == handle.insertedText ? nil : observed
    }

    @MainActor
    private func insertionWasObserved(_ handle: InsertionHandle) -> Bool {
        guard let element = handle.element,
              let current = focusedElement(),
              CFEqual(element, current) else { return false }
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(current, &processIdentifier)
        guard processIdentifier == handle.processIdentifier else { return false }

        if let prefix = handle.prefix,
           let suffix = handle.suffix,
           let value = stringValue(of: current) {
            return value == prefix + handle.insertedText + suffix
        }
        if let unaffectedCharacterCount = handle.unaffectedCharacterCount,
           let currentCharacterCount = characterCount(of: current) {
            return currentCharacterCount
                == unaffectedCharacterCount + (handle.insertedText as NSString).length
        }
        return false
    }

    static func textBetweenAnchors(
        in snapshot: String,
        insertionOffset: Int,
        beforeAnchor: String,
        afterAnchor: String,
        inferredEndOffset: Int? = nil,
        cursorOffset: Int?
    ) -> String? {
        let source = snapshot as NSString
        guard insertionOffset >= 0, insertionOffset <= source.length else { return nil }

        var start = insertionOffset
        if !beforeAnchor.isEmpty {
            let searchRange = NSRange(location: 0, length: insertionOffset)
            let found = source.range(
                of: beforeAnchor,
                options: [.backwards],
                range: searchRange
            )
            guard found.location != NSNotFound else { return nil }
            start = NSMaxRange(found)
        }

        let end: Int
        if !afterAnchor.isEmpty {
            let searchRange = NSRange(location: start, length: source.length - start)
            let found = source.range(of: afterAnchor, range: searchRange)
            guard found.location != NSNotFound else { return nil }
            end = found.location
        } else if let inferredEndOffset,
                  inferredEndOffset >= start,
                  inferredEndOffset <= source.length {
            end = inferredEndOffset
        } else if let cursorOffset,
                  cursorOffset >= start,
                  cursorOffset <= source.length {
            end = cursorOffset
        } else {
            end = source.length
        }
        guard end >= start else { return nil }
        return source.substring(with: NSRange(location: start, length: end - start))
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
    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        if Self.isTextInputRole(role: role, subrole: subrole) {
            return true
        }

        // Web content-editable controls do not always expose a standard text role.
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        return result == .success && isSettable.boolValue
    }

    static func isTextInputRole(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("textfield")
                    || value.contains("textarea")
                    || value.contains("textinput")
                    || value.contains("searchfield")
                    || value == "axcombobox"
            }
    }

    @MainActor
    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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
    private func contextAnchors(
        for element: AXUIElement,
        selection: CFRange?,
        boundaries: (String, String)?
    ) -> (before: String, after: String) {
        let anchorLength = 48
        if let boundaries {
            let before = boundaries.0 as NSString
            let after = boundaries.1 as NSString
            return (
                before.substring(from: max(0, before.length - anchorLength)),
                after.substring(to: min(anchorLength, after.length))
            )
        }
        guard let selection else { return ("", "") }
        let beforeLength = min(anchorLength, max(0, selection.location))
        let before = string(
            in: CFRange(location: selection.location - beforeLength, length: beforeLength),
            of: element
        ) ?? ""
        let afterStart = selection.location + selection.length
        let afterLength = characterCount(of: element)
            .map { min(anchorLength, max(0, $0 - afterStart)) } ?? 0
        let after = afterLength > 0
            ? string(in: CFRange(location: afterStart, length: afterLength), of: element) ?? ""
            : ""
        return (before, after)
    }

    private struct CorrectionSnapshot {
        let text: String
        let baseLocation: Int
        let cursorLocation: Int?
        let inferredEndLocation: Int?
    }

    @MainActor
    private func correctionSnapshot(
        for element: AXUIElement,
        insertionLocation: Int,
        insertedLength: Int,
        beforeAnchor: String,
        afterAnchor: String,
        unaffectedCharacterCount: Int?
    ) -> CorrectionSnapshot? {
        let focused = focusedElement()
        let cursor = focused.flatMap { current -> Int? in
            guard CFEqual(current, element),
                  let range = selectedRange(of: current),
                  range.length == 0 else { return nil }
            return range.location
        }
        let count = characterCount(of: element)
        let inferredEnd = count.flatMap { count -> Int? in
            guard let unaffectedCharacterCount else { return nil }
            return insertionLocation + max(0, count - unaffectedCharacterCount)
        }
        if let value = stringValue(of: element) {
            return CorrectionSnapshot(
                text: value,
                baseLocation: 0,
                cursorLocation: cursor,
                inferredEndLocation: inferredEnd
            )
        }

        guard let count else { return nil }
        let beforeLength = (beforeAnchor as NSString).length
        let afterLength = (afterAnchor as NSString).length
        let start = max(0, insertionLocation - beforeLength)
        let expectedEnd = insertionLocation + insertedLength + afterLength + 64
        let cursorEnd = cursor.map { $0 + afterLength + 16 } ?? 0
        let inferredReadEnd = inferredEnd.map { $0 + afterLength + 16 } ?? 0
        let end = min(count, max(expectedEnd, max(cursorEnd, inferredReadEnd)))
        guard end >= start,
              let text = string(
                  in: CFRange(location: start, length: end - start),
                  of: element
              ) else { return nil }
        return CorrectionSnapshot(
            text: text,
            baseLocation: start,
            cursorLocation: cursor,
            inferredEndLocation: inferredEnd
        )
    }

    @MainActor
    private func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXNumberOfCharacters" as CFString,
            &value
        ) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    @MainActor
    private func string(in range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        return value as? String
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
