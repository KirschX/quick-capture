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

/// Watches the mouse for the trigger chosen in Settings. For the left + right chords, each button press is held back
/// for a moment to see whether the other button joins it; on its own it's let through unchanged, so ordinary clicks
/// and drags still work. A trigger never reaches the app under the mouse. Needs Accessibility, to watch and hold back clicks.
final class MouseChord {
    static let shared = MouseChord()
    /// How long a press waits for the other button. Short enough not to notice on a click; a drag lets it through at once.
    private static let window: Duration = .milliseconds(60)
    /// How long both buttons must stay down for `chordHold`.
    private static let hold: Duration = .milliseconds(200)
    /// Marks the events this sends back out after holding them, so they aren't held again.
    private static let replayMarker: Int64 = 0x5143_4150

    private var tap: CFMachPort?
    /// A button press being held back, waiting to see if the other button joins it.
    private var pending: CGEvent?
    /// With `chordHold`: both presses, held back until the buttons have stayed down long enough.
    private var candidate: [CGEvent] = []
    private var generation = 0
    /// After a trigger, its buttons' releases (and any dragging until then) are swallowed.
    private var releasesToSwallow = 0

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
        let trigger = MouseTrigger.current

        // Finish what a trigger started, even if the setting changed meanwhile.
        if releasesToSwallow > 0 {
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp { releasesToSwallow -= 1 }
            return nil
        }
        if !candidate.isEmpty {
            switch type {
            case .leftMouseUp, .rightMouseUp:
                // Let go too soon for a hold: both presses happen after all, then this release.
                return releasingFirst(event)
            default:
                return nil
            }
        }

        switch type {
        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let matches = (trigger == .middle && button == 2) || (trigger == .side && (button == 3 || button == 4))
            guard matches else { return releasingFirst(event) }
            releasesToSwallow = 1
            CaptureCoordinator.shared.toggleCapture()
            return nil
        case .leftMouseDown, .rightMouseDown:
            if let held = pending, held.type != type {
                // The other button joined in time.
                pending = nil
                generation += 1
                if trigger == .chordHold, let copy = event.copy() {
                    candidate = [held, copy]
                    let current = generation
                    Task {
                        try? await Task.sleep(for: Self.hold)
                        if generation == current, !candidate.isEmpty { fire() }
                    }
                } else {
                    fire()
                }
                return nil
            }
            if pending != nil { release() }
            guard trigger.usesChord else { return pass }
            pending = event.copy()
            generation += 1
            let current = generation
            Task {
                try? await Task.sleep(for: Self.window)
                if generation == current { release() }
            }
            return nil
        default:
            return releasingFirst(event)
        }
    }

    /// Both chord buttons are down: start the capture, and swallow both releases.
    private func fire() {
        candidate = []
        generation += 1
        releasesToSwallow = 2
        CaptureCoordinator.shared.toggleCapture()
    }

    /// Sends anything held back on before `event`, keeping their order: it all goes back out, the held presses first.
    private func releasingFirst(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard pending != nil || !candidate.isEmpty, let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        release()
        post(copy)
        return nil
    }

    /// Lets held presses through, as they were.
    private func release() {
        let held = (pending.map { [$0] } ?? []) + candidate
        pending = nil
        candidate = []
        generation += 1
        held.forEach(post)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cgSessionEventTap)
    }
}
