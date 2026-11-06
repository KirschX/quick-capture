import AppKit
import CoreGraphics

/// The mouse action that starts a capture (or closes the open one), chosen in Settings.
enum MouseTrigger: String, CaseIterable, Identifiable {
    /// Left and right buttons pressed together.
    case chord
    /// Left and right buttons held down together for a moment, so a stray overlap never starts one.
    case chordHold
    /// The middle button (wheel click).
    case middle
    /// Either side button (back or forward).
    case side
    case off

    static let defaultsKey = "mouseTrigger"

    var id: Self { self }

    var title: String {
        switch self {
        case .chord: "Left + right click together"
        case .chordHold: "Hold left + right together"
        case .middle: "Middle button (wheel click)"
        case .side: "Side button (back / forward)"
        case .off: "Off"
        }
    }

    static var current: MouseTrigger {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MouseTrigger.init) ?? .chord
    }

    var usesChord: Bool { self == .chord || self == .chordHold }
}

/// Watches the mouse for the trigger chosen in Settings. The left button is never held back or re-sent, so clicks,
/// drags and text selection work exactly as without the app. For the left + right chords only a right press waits a
/// moment (to see whether it's part of a chord) and is then let through unchanged. A trigger's presses never reach
/// the app under the mouse, except a left press that came first, which already had. Needs Accessibility.
final class MouseChord {
    static let shared = MouseChord()
    /// How long a right press waits for the left button.
    private static let window: Duration = .milliseconds(60)
    /// How long both buttons must stay down for `chordHold`.
    private static let hold: Duration = .milliseconds(200)
    /// Marks the events this sends back out after holding them, so they aren't held again.
    private static let replayMarker: Int64 = 0x5143_4150

    private enum Button { case left, right, other }

    private var tap: CFMachPort?
    /// A right press being held back, waiting to see if the left button joins it.
    private var pendingRight: CGEvent?
    /// With `chordHold`: the held-back presses of a chord, until the buttons have stayed down long enough.
    private var candidate: [CGEvent] = []
    private var generation = 0
    /// Buttons whose release (and dragging until then) is swallowed, because their press started a capture.
    private var swallowing: Set<Button> = []

    /// Starts watching clicks, retrying until Accessibility is granted.
    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let chord = Unmanaged<MouseChord>.fromOpaque(info).takeUnretainedValue()
            // The tap's run loop source is on the main run loop, so this is called on the main thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: Unmanaged<CGEvent>?
            MainActor.assumeIsolated { result = chord.handle(type, event) }
            return result
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Task {
                try? await Task.sleep(for: .seconds(2))
                start()
            }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return pass }

        switch type {
        case .leftMouseDown:
            if let right = pendingRight, MouseTrigger.current.usesChord {
                // Right then left: neither press reaches the app.
                pendingRight = nil
                chord(held: [right, event.copy()].compactMap { $0 }, swallow: [.left, .right])
                return nil
            }
            return pass
        case .leftMouseUp:
            if swallowing.remove(.left) != nil { return nil }
            return releasingFirst(event)
        case .leftMouseDragged:
            return swallowing.contains(.left) ? nil : pass

        case .rightMouseDown:
            guard MouseTrigger.current.usesChord, swallowing.isEmpty, candidate.isEmpty else { return pass }
            // Asked of the hardware rather than tracked, so a missed release can never turn right clicks into captures.
            if CGEventSource.buttonState(.hidSystemState, button: .left) {
                // Left then right: the left press already reached the app; only the right one is kept from it.
                chord(held: [event.copy()].compactMap { $0 }, swallow: [.right])
                return nil
            }
            if pendingRight != nil { release() }
            pendingRight = event.copy()
            generation += 1
            let current = generation
            Task {
                try? await Task.sleep(for: Self.window)
                if generation == current { release() }
            }
            return nil
        case .rightMouseUp:
            if swallowing.remove(.right) != nil { return nil }
            return releasingFirst(event)
        case .rightMouseDragged:
            if swallowing.contains(.right) { return nil }
            return releasingFirst(event)

        case .otherMouseDown:
            let trigger = MouseTrigger.current
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard (trigger == .middle && button == 2) || (trigger == .side && (button == 3 || button == 4)) else { return pass }
            swallowing.insert(.other)
            CaptureCoordinator.shared.toggleCapture()
            return nil
        case .otherMouseUp:
            return swallowing.remove(.other) != nil ? nil : pass
        case .otherMouseDragged:
            return swallowing.contains(.other) ? nil : pass
        default:
            return pass
        }
    }

    /// Both buttons are down. With `chord` the capture starts now; with `chordHold` once they've stayed down long
    /// enough, or the held presses go through as they were if a button comes up first.
    private func chord(held: [CGEvent], swallow: Set<Button>) {
        generation += 1
        guard MouseTrigger.current == .chordHold else {
            fire(swallow)
            return
        }
        candidate = held
        let current = generation
        Task {
            try? await Task.sleep(for: Self.hold)
            if generation == current, !candidate.isEmpty { fire(swallow) }
        }
    }

    private func fire(_ swallow: Set<Button>) {
        candidate = []
        generation += 1
        swallowing.formUnion(swallow)
        CaptureCoordinator.shared.toggleCapture()
    }

    /// Sends anything held back on before `event`, keeping their order: the held presses first, then this.
    private func releasingFirst(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard pendingRight != nil || !candidate.isEmpty, let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        release()
        post(copy)
        return nil
    }

    /// Lets held presses through, as they were.
    private func release() {
        let held = (pendingRight.map { [$0] } ?? []) + candidate
        pendingRight = nil
        candidate = []
        generation += 1
        held.forEach(post)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cgSessionEventTap)
    }
}
