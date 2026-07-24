import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack {
                NotchShape(radius: model.phase == .idle ? 11 : 18)
                    .fill(.black)
                    .frame(
                        height: model.phase == .idle
                            ? NotchLayout.physicalNotchHeight(on: NotchLayout.notchedScreen())
                            : nil
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                    .shadow(color: .black.opacity(model.phase == .idle ? 0 : 0.42), radius: 16, y: 9)

                content
                    .padding(.horizontal, 15)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onHover(perform: handleHover)
            .animation(.easeOut(duration: 0.10), value: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            Color.clear
        case .peek:
            ZStack(alignment: .leading) {
                logo(size: 72)
                    .offset(x: -8, y: 8)
                VStack(spacing: 8) {
                    Text("How do you want this to sound?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        ForEach(WritingMode.allCases) { mode in
                            Button {
                                model.chooseMode(mode)
                            } label: {
                                Label(mode.rawValue, systemImage: mode.systemImage)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 9)
                                    .frame(height: 27)
                                    .background(model.selectedMode == mode ? Color.white : Color.white.opacity(0.1))
                                    .foregroundStyle(model.selectedMode == mode ? .black : .white.opacity(0.76))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.rawValue)
                            .accessibilityValue(model.selectedMode == mode ? "Selected" : "Not selected")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(minHeight: 72)
            .padding(.top, NotchLayout.expandedContentTopInset(on: NotchLayout.notchedScreen()))
        case .listening:
            VStack(spacing: 5) {
                HStack(spacing: 11) {
                    NotchLogo(size: 24)
                    waveform
                    Text(model.selectedMode.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Circle()
                        .fill(Color(red: 1, green: 0.34, blue: 0.32))
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.7), radius: 5)
                    Text("REC")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
                }
                if !model.partialTranscript.isEmpty {
                    Text(model.partialTranscript)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            // The top of this panel is underneath the MacBook's physical cutout.
            // Keep the live waveform below it so none of the bars are obscured.
            .padding(.top, NotchLayout.physicalNotchHeight(on: NotchLayout.notchedScreen()) + 7)
        case .processing:
            HStack(spacing: 11) {
                logo(size: 22)
                ProgressView().controlSize(.small).tint(.white)
                Text(model.isUsingCloud ? "Cloud polishing…" : "Polishing…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                if model.isUsingCloud {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, NotchLayout.expandedContentTopInset(on: NotchLayout.notchedScreen()))
        case .done:
            Label("Inserted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.65, green: 0.95, blue: 0.45))
                .padding(.top, NotchLayout.expandedContentTopInset(on: NotchLayout.notchedScreen()))
        case let .error(message):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            }
            .padding(.top, NotchLayout.expandedContentTopInset(on: NotchLayout.notchedScreen()))
        }
    }

    private func handleHover(_ isHovering: Bool) {
        if isHovering {
            model.showPeek()
        } else {
            model.schedulePeekDismissal()
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< 23, id: \.self) { index in
                let rhythm = CGFloat((index * 7) % 11) / 11
                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: 2.2, height: max(3, CGFloat(model.audioLevel) * (8 + rhythm * 19)))
                    .animation(.easeOut(duration: 0.12), value: model.audioLevel)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26)
    }

    @ViewBuilder
    private func logo(size: CGFloat) -> some View {
        NotchLogo(size: size)
    }
}

enum NotchLayout {
    /// The UI belongs to the MacBook's physical notch, irrespective of which display
    /// contains the pointer or is currently the main display.
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Use the measured cutout rather than the screen midpoint. They normally match,
    /// but the measured value remains correct with asymmetric menu-bar safe areas.
    static func notchCenterX(on screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return screen.frame.midX
        }
        return (left.maxX + right.minX) / 2
    }

    static func size(
        for phase: DictationPhase,
        hasTranscript: Bool = false,
        on screen: NSScreen?
    ) -> NSSize {
        switch phase {
        case .idle:
            // A generous transparent hover strip sits below the hardware cutout so
            // the panel opens as soon as the pointer tip reaches the notch.
            // The visible black shape remains the exact physical notch size.
            return NSSize(width: physicalNotchWidth(on: screen), height: physicalNotchHeight(on: screen) + 16)
        case .peek:
            return NSSize(width: 390, height: physicalNotchHeight(on: screen) + 88)
        case .listening:
            let notchHeight = physicalNotchHeight(on: screen)
            return NSSize(width: 350, height: notchHeight + (hasTranscript ? 64 : 44))
        case .processing:
            return NSSize(width: 270, height: physicalNotchHeight(on: screen) + 44)
        case .done:
            return NSSize(width: 150, height: physicalNotchHeight(on: screen) + 36)
        case .error:
            return NSSize(width: 360, height: physicalNotchHeight(on: screen) + 48)
        }
    }

    private static func physicalNotchWidth(on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 170 }
        let measured = screen.frame.width - left.width - right.width
        return min(max(measured, 150), 230)
    }

    static func physicalNotchHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 32 }
        let measured = max(left.height, right.height)
        return min(max(measured, 28), 40)
    }

    static func expandedContentTopInset(on screen: NSScreen?) -> CGFloat {
        physicalNotchHeight(on: screen) + 7
    }
}

/// The audio meter publishes many updates per second. Loading the SVG from disk in
/// `NotchView.body` for every update made the logo flash between rendered frames.
/// Reusing one image and opting it out of waveform transactions keeps it stable.
private struct NotchLogo: View {
    let size: CGFloat

    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AirScribeIcon", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            } else {
                RoundedRectangle(cornerRadius: size * 0.23)
                    .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Text("A").font(.system(size: size * 0.45, weight: .black)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
