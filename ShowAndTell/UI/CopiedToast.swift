import AppKit
import SwiftUI

/// A small pill confirming a copy, low in the middle of the screen. It fades in, stays briefly and fades out;
/// it never takes focus or clicks, so it doesn't get in the way of pasting.
final class CopiedToast: NSPanel {
    private static var shown: CopiedToast?
    private static let holdDuration = Duration.seconds(1.4)

    static func show(_ message: String, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        shown?.orderOut(nil)
        let toast = CopiedToast(message: message, screen: screen)
        shown = toast
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            toast.animator().alphaValue = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: holdDuration)
            guard shown === toast else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }
            guard shown === toast else { return }
            toast.orderOut(nil)
            shown = nil
        }
    }

    private init(message: String, screen: NSScreen) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: ToastView(message: message))
        hosting.safeAreaRegions = []
        // Keep the frame set below; by default the hosting view shrinks the panel to the pill, from its left edge.
        hosting.sizingOptions = []
        contentView = hosting
        // Wider than the pill, which sits centred in it: the first layout can measure the text short. The extra is clear
        // and lets clicks through.
        let size = CGSize(width: hosting.fittingSize.width + 160, height: hosting.fittingSize.height)
        // Centred, a fifth of the way up the screen: above the Dock, below where you're looking.
        let visible = screen.visibleFrame
        setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height / 5,
                        width: size.width, height: size.height), display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.title3.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
