import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import UniformTypeIdentifiers

struct TextInserter: Sendable {
    enum InsertionResult: Sendable {
        case inserted(InsertionHandle)
        case typed
        case copiedToClipboard

        var handle: InsertionHandle? {
            switch self {
            case let .inserted(handle):
                return handle
            case .typed, .copiedToClipboard:
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
    func insert(
        _ text: String,
        allowClipboardFallback: Bool = true
    ) async throws -> InsertionResult {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let targetsTerminal = Self.isTerminalApplication(
            bundleIdentifier: frontmostApplication?.bundleIdentifier
        )

        /// Copying overwrites whatever the user had on the clipboard, so the
        /// fallback is skippable: with it off, an unverifiable insertion reports
        /// a failure and leaves the clipboard alone.
        func fallbackToClipboard() throws -> InsertionResult {
            guard allowClipboardFallback else { throw AirScribeError.insertionNotVerified }
            try copyToClipboard(text)
            return .copiedToClipboard
        }

        // Clipboard fallback must remain available even when macOS has stale or
        // missing Accessibility authorization. A terminal is different: silently
        // copying there looks like a failed insertion, so report the permission
        // problem without changing the clipboard.
        guard !SecureInputGuard.isSecure(nil) else { throw AirScribeError.secureInputActive }
        guard AXIsProcessTrusted() else {
            if targetsTerminal {
                throw AirScribeError.accessibilityPermissionDenied
            }
            return try fallbackToClipboard()
        }

        let element = focusedElement()
        guard !SecureInputGuard.isSecure(element) else { throw AirScribeError.secureInputActive }
        if targetsTerminal, let frontmostApplication {
            let safeText = Self.terminalSafeText(text)
            guard !safeText.isEmpty else { throw AirScribeError.emptyTranscription }
            try await typeIntoTerminal(
                safeText,
                processIdentifier: frontmostApplication.processIdentifier
            )
            return .typed
        }
        guard let element, isEditableTextElement(element) else {
            return try fallbackToClipboard()
        }
        // An element that exposes neither role nor subrole cannot be shown to be
        // a non-secure field, and synthesising ⌘V into it would type the
        // transcript somewhere unverifiable. Treat unknown as unsafe, matching
        // how context capture already fails closed.
        guard hasReadableRole(element) else {
            return try fallbackToClipboard()
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

        // Prefer Accessibility insertion so the user's clipboard is untouched.
        // If an editor accepts the write but does not expose enough state to
        // verify it, avoid a second paste that could duplicate the text.
        if Self.isTextInputRole(
            role: stringAttribute(kAXRoleAttribute, of: element),
            subrole: stringAttribute(kAXSubroleAttribute, of: element)
        ), AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success {
            for delay in [35, 70, 120] {
                try? await Task.sleep(for: .milliseconds(delay))
                if insertionWasObserved(handle) {
                    return .inserted(handle)
                }
            }
            return try fallbackToClipboard()
        }

        let pasteboard = NSPasteboard.general
        guard let snapshot = snapshotPasteboard(pasteboard) else {
            // Do not materialize or destroy large images, files, and custom
            // application clipboard payloads merely to perform a paste.
            return try fallbackToClipboard()
        }
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
        // Restore the user's clipboard first when the fallback is disabled.
        guard allowClipboardFallback else {
            if pasteboard.changeCount == insertionChangeCount {
                restorePasteboard(snapshot, to: pasteboard)
            }
            throw AirScribeError.insertionNotVerified
        }
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
    func insertionHandleForRecentlyPastedText(_ text: String) -> InsertionHandle? {
        guard !text.isEmpty,
              AXIsProcessTrusted(),
              let element = focusedElement(),
              !SecureInputGuard.isSecure(element),
              hasReadableRole(element),
              isEditableTextElement(element),
              let value = stringValue(of: element),
              let selection = selectedRange(of: element),
              let range = Self.pastedTextRange(
                  in: value,
                  selection: NSRange(location: selection.location, length: selection.length),
                  pastedText: text
              ) else {
            return nil
        }

        let source = value as NSString
        let prefix = source.substring(to: range.location)
        let suffix = source.substring(from: NSMaxRange(range))
        let anchors = contextAnchors(
            for: element,
            selection: CFRange(location: range.location, length: range.length),
            boundaries: (prefix, suffix)
        )
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return InsertionHandle(
            id: UUID(),
            element: element,
            processIdentifier: processIdentifier,
            insertionLocation: range.location,
            insertedText: text,
            prefix: prefix,
            suffix: suffix,
            beforeAnchor: anchors.before,
            afterAnchor: anchors.after,
            unaffectedCharacterCount: max(0, source.length - range.length)
        )
    }

    static func pastedTextRange(
        in value: String,
        selection: NSRange,
        pastedText: String
    ) -> NSRange? {
        let source = value as NSString
        let pastedLength = (pastedText as NSString).length
        guard pastedLength > 0,
              selection.location >= 0,
              selection.length >= 0,
              NSMaxRange(selection) <= source.length else {
            return nil
        }

        let candidate: NSRange
        if selection.length == pastedLength {
            candidate = selection
        } else if selection.length == 0, selection.location >= pastedLength {
            candidate = NSRange(location: selection.location - pastedLength, length: pastedLength)
        } else {
            return nil
        }
        guard source.substring(with: candidate) == pastedText else { return nil }
        return candidate
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
              let current = focusedElement(),
              CFEqual(element, current),
              !SecureInputGuard.isSecure(element),
              !SecureInputGuard.isSecure(current),
              hasReadableRole(current) else { return nil }

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
    func canObserveCorrection(_ handle: InsertionHandle) -> Bool {
        guard AXIsProcessTrusted(),
              let element = handle.element,
              let current = focusedElement(),
              CFEqual(element, current),
              !SecureInputGuard.isSecure(current),
              hasReadableRole(current) else {
            return false
        }
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(current, &processIdentifier)
        return processIdentifier == handle.processIdentifier
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
    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let sourceItems = pasteboard.pasteboardItems ?? []
        guard sourceItems.count <= 16 else { return nil }
        var totalBytes = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in sourceItems {
            guard item.types.count <= 32,
                  item.types.allSatisfy(Self.isSafeTextPasteboardType) else { return nil }
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                totalBytes += data.count
                guard totalBytes <= 4 * 1_024 * 1_024 else { return nil }
                stored[type] = data
            }
            items.append(stored)
        }
        return PasteboardSnapshot(items: items)
    }

    static func isSafeTextPasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string || type == .rtf || type == .html || type == .tabularText {
            return true
        }
        return UTType(type.rawValue)?.conforms(to: .text) == true
    }

    static func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?.lowercased() else { return false }
        return [
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp",
            "dev.warp.warp-stable",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "io.alacritty",
            "com.github.wez.wezterm",
            "com.mitchellh.ghostty",
            "com.raphaelamorim.rio",
        ].contains(bundleIdentifier)
    }

    static func terminalSafeText(_ text: String) -> String {
        let withoutControls = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        return withoutControls
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func terminalTypingChunks(_ text: String, maximumUTF16Count: Int = 16) -> [String] {
        guard maximumUTF16Count > 0 else { return [] }
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for character in text {
            let value = String(character)
            let count = value.utf16.count
            if !current.isEmpty, currentCount + count > maximumUTF16Count {
                chunks.append(current)
                current = ""
                currentCount = 0
            }
            current.append(character)
            currentCount += count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    @MainActor
    private func typeIntoTerminal(_ text: String, processIdentifier: pid_t) async throws {
        guard NSRunningApplication(processIdentifier: processIdentifier) != nil,
              let source = CGEventSource(stateID: .hidSystemState) else {
            throw AirScribeError.accessibilityPermissionDenied
        }

        for chunk in Self.terminalTypingChunks(text) {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_A),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_A),
                keyDown: false
            ) else {
                throw AirScribeError.accessibilityPermissionDenied
            }
            let characters = Array(chunk.utf16)
            characters.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
            try? await Task.sleep(for: .milliseconds(3))
        }
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
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// True when Accessibility exposes at least one role string for the element.
    ///
    /// `SecureInputGuard` can only clear a field it can describe; an element with
    /// no readable role is indistinguishable from a password field, so callers
    /// treat this as a refusal rather than as permission.
    @MainActor
    func hasReadableRole(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: element) != nil
            || stringAttribute(kAXSubroleAttribute, of: element) != nil
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
