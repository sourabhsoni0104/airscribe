import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelController {
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var phaseObserver: AnyCancellable?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if panel == nil { panel = makePanel(model: model) }
        positionPanel()
        panel?.orderFrontRegardless()

        phaseObserver = model.$phase
            .combineLatest(model.$partialTranscript.map { !$0.isEmpty }.removeDuplicates())
            .sink { [weak self] state in
                // Publishing can occur while SwiftUI is laying out the hosted
                // content. Defer the AppKit frame mutation to the next main-loop
                // turn to avoid recursively laying out the panel.
                Task { @MainActor [weak self] in
                    self?.positionPanel(
                        animated: true,
                        phase: state.0,
                        hasTranscript: state.1
                    )
                }
            }

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            }
        }
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let screen = NotchLayout.notchedScreen()
        let panelSize = NotchLayout.size(for: model.phase, on: screen)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        let hostingView = NSHostingView(rootView: NotchView(model: model))
        // The controller owns the window geometry. If the hosting view is allowed to
        // resize its window from SwiftUI's intrinsic size, expansion keeps the old
        // left edge and makes the notch appear far to the right.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let containerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        // A neutral AppKit container prevents the hosting view's intrinsic content
        // size from ever becoming the window's frame size.
        panel.contentView = containerView
        return panel
    }

    private func positionPanel(
        animated: Bool = false,
        phase: DictationPhase? = nil,
        hasTranscript: Bool? = nil
    ) {
        guard let panel, let model else { return }
        let screen = NotchLayout.notchedScreen()
        guard let screen else { return }
        let targetPhase = phase ?? model.phase
        let targetHasTranscript = hasTranscript ?? !model.partialTranscript.isEmpty
        let size = NotchLayout.size(
            for: targetPhase,
            hasTranscript: targetHasTranscript,
            on: screen
        )
        let frame = NSRect(
            x: (NotchLayout.notchCenterX(on: screen) - size.width / 2).rounded(),
            y: (screen.frame.maxY - size.height).rounded(),
            width: size.width,
            height: size.height
        )

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = targetPhase == .peek ? 0.08 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

}
