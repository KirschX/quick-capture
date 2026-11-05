import AppKit
import SwiftUI

/// The floating stop button shown while recording. It never takes focus, so the app being recorded keeps
/// its hover and pressed states, and it's left out of the recording.
final class RecordingPill: NSPanel {
    init(screen: NSScreen, started: Date, onStop: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = FirstMouseHostingView(rootView: PillView(started: started, onStop: onStop))
        hosting.safeAreaRegions = []
        contentView = hosting
        let size = hosting.fittingSize
        // Centred near the bottom of the screen, clear of the Dock.
        let visible = screen.visibleFrame
        setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height), display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PillView: View {
    let started: Date
    let onStop: () -> Void
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(isPulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: isPulsing)
                .onAppear { isPulsing = true }
            Text(timerInterval: started...started.addingTimeInterval(3600), countsDown: false)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 36, alignment: .leading)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.red))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(12)
    }
}
