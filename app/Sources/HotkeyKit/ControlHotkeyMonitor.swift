import AppKit
import CoreGraphics

enum DictationHotkey: String, CaseIterable, Identifiable {
    case control
    case option
    case command
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: "Control (⌃)"
        case .option: "Option (⌥)"
        case .command: "Command (⌘)"
        case .function: "Fn"
        }
    }

    fileprivate var keyCodes: Set<Int64> {
        switch self {
        case .control: [59, 62]
        case .option: [58, 61]
        case .command: [54, 55]
        case .function: [63]
        }
    }

    fileprivate func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .control: flags.contains(.control)
        case .option: flags.contains(.option)
        case .command: flags.contains(.command)
        case .function: flags.contains(.function)
        }
    }

    fileprivate func isPressed(in flags: CGEventFlags) -> Bool {
        switch self {
        case .control: flags.contains(.maskControl)
        case .option: flags.contains(.maskAlternate)
        case .command: flags.contains(.maskCommand)
        case .function: flags.contains(.maskSecondaryFn)
        }
    }
}

private func controlHotkeyEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ControlHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in monitor.reenableEventTap() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    Task { @MainActor in
        monitor.handleCGEvent(type: type, flags: flags, keyCode: keyCode)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class ControlHotkeyMonitor: NSObject {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var selectedHotkey: DictationHotkey = .control

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var controlPollingTimer: Timer?
    private var state = ControlHotkeyStateMachine()
    private var pendingEndTask: Task<Void, Never>?

    func start() throws {
        guard globalMonitor == nil,
              localMonitor == nil,
              eventTap == nil,
              controlPollingTimer == nil else { return }

        let eventMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: controlHotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            eventTap = tap
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        // Prefer a single event source. Feeding one fast modifier transition
        // through the event tap, NSEvent monitor, and polling loop can reorder a
        // double press and cancel hands-free mode.
        if eventTap == nil {
            let mask: NSEvent.EventTypeMask = [.flagsChanged]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }

            let pollingTimer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(pollControlState),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(pollingTimer, forMode: .common)
            controlPollingTimer = pollingTimer
        }

        guard eventTap != nil || globalMonitor != nil || controlPollingTimer != nil else {
            stop()
            throw AirScribeError.accessibilityPermissionDenied
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        controlPollingTimer?.invalidate()
        pendingEndTask?.cancel()
        globalMonitor = nil
        localMonitor = nil
        eventTapSource = nil
        eventTap = nil
        controlPollingTimer = nil
        state = ControlHotkeyStateMachine()
        pendingEndTask = nil
    }

    func reset() {
        pendingEndTask?.cancel()
        state = ControlHotkeyStateMachine()
        pendingEndTask = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        guard selectedHotkey.keyCodes.contains(Int64(event.keyCode)) else { return }

        if let action = state.handleControlTransition(
            isDown: selectedHotkey.isPressed(in: event.modifierFlags)
        ) {
            perform(action)
        }
    }

    func handleCGEvent(type: CGEventType, flags: CGEventFlags, keyCode: Int64) {
        guard type == .flagsChanged, selectedHotkey.keyCodes.contains(keyCode) else { return }
        if let action = state.handleControlTransition(isDown: selectedHotkey.isPressed(in: flags)) {
            perform(action)
        }
    }

    func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    @objc private func pollControlState() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if let action = state.handleControlTransition(isDown: selectedHotkey.isPressed(in: flags)) {
            perform(action)
        }
    }

    private func perform(_ action: ControlHotkeyStateMachine.Action) {
        switch action {
        case .begin:
            pendingEndTask?.cancel()
            onBegin?()
        case .end:
            pendingEndTask?.cancel()
            onEnd?()
        case .latch:
            pendingEndTask?.cancel()
        case .scheduleEnd:
            scheduleEndIfStillPending()
        }
    }

    private func scheduleEndIfStillPending() {
        pendingEndTask?.cancel()
        pendingEndTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(Int(self.state.doubleTapInterval * 1_000)))
            guard !Task.isCancelled else { return }
            self.pendingEndTask = nil
            guard self.state.finishListeningIfPendingEndStillValid() else { return }
            self.onEnd?()
        }
    }
}

struct ControlHotkeyStateMachine {
    enum Action: Sendable, Equatable {
        case begin
        case end
        case latch
        case scheduleEnd
    }

    var controlIsDown = false
    var dictationIsActive = false
    var latched = false
    // Leave enough time for an intentional modifier double press.
    let doubleTapInterval: TimeInterval = 0.55

    mutating func handleControlTransition(isDown: Bool) -> Action? {
        if isDown, !controlIsDown {
            controlIsDown = true
            if dictationIsActive {
                if latched {
                    dictationIsActive = false
                    latched = false
                    return .end
                }
                latched = true
                return .latch
            }
            dictationIsActive = true
            latched = false
            return .begin
        }

        if !isDown, controlIsDown {
            controlIsDown = false
            if dictationIsActive, !latched {
                return .scheduleEnd
            }
        }
        return nil
    }

    mutating func finishListeningIfPendingEndStillValid() -> Bool {
        guard dictationIsActive, !latched, !controlIsDown else { return false }
        dictationIsActive = false
        return true
    }
}
