import AppKit
import SwiftUI

/// The full-screen window the overlay is drawn in.
final class OverlayPanel: NSPanel {
    init<Content: View>(screen: NSScreen, content: Content) {
        // Non-activating, like Spotlight: it takes typing straight away without a click to focus it.
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        show(content)
        setFrame(screen.frame, display: true)
    }

    /// Replaces what the panel shows, e.g. when stepping to another capture in history.
    func show<Content: View>(_ content: Content) {
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.safeAreaRegions = []
        contentView = hosting
        // A swapped-in view doesn't get the keyboard by itself; without this, keys just beep.
        makeFirstResponder(hosting)
    }

    /// No beep for a key nothing handled, like a held , landing just as a history step swaps the view in,
    /// before the new one has the keyboard. No key in the overlay deserves a "can't do that" sound.
    override func noResponder(for eventSelector: Selector) {
        guard eventSelector != #selector(NSResponder.keyDown(with:)) else { return }
        super.noResponder(for: eventSelector)
    }

    /// ⌘Z and ⇧⌘Z undo typing in a note. The overlay has no Edit menu to send them, and sending them
    /// from a SwiftUI button's action leaves the note's binding holding the old text.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let note = firstResponder as? NSTextView, event.charactersIgnoringModifiers?.lowercased() == "z",
           flags == .command || flags == [.command, .shift] {
            return note.tryToPerform(flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")), with: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Called when Return (without ⇧ or ⌥) is pressed while typing a note.
    var onSubmitNote: (() -> Void)?

    /// Return in a note submits instead of adding a line; ⇧↩ or ⌥↩ still add one. A word still being composed by an
    /// input method (Korean, Japanese…) is committed first, so its last syllable isn't lost.
    override func sendEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           flags.isDisjoint(with: [.shift, .option, .command, .control]),
           let note = firstResponder as? NSTextView, onSubmitNote != nil {
            if note.hasMarkedText() {
                note.unmarkText()
                note.inputContext?.discardMarkedText()
                note.didChangeText()
            }
            // On the next turn of the run loop, after the note's binding has taken the committed text.
            perform(#selector(submitNote), with: nil, afterDelay: 0)
            return
        }
        super.sendEvent(event)
    }

    @objc private func submitNote() {
        onSubmitNote?()
    }

    /// Borderless panels can't take typing unless they say so.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The first click acts (annotates, or presses a button) instead of only focusing the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
