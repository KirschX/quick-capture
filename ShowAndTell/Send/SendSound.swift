import AppKit

/// The sound played when a capture is copied: SND01 "sine" by Yasuhiro Tsuchiya (https://snd.dev), used unmodified.
enum SendSound: String, CaseIterable, Identifiable {
    case off
    case button
    case tap3 = "tap_03"
    case tap4 = "tap_04"
    case tap5 = "tap_05"

    static let defaultsKey = "sendSound"

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "None"
        case .button: "Button"
        case .tap3: "Tap 3"
        case .tap4: "Tap 4"
        case .tap5: "Tap 5"
        }
    }

    static var current: SendSound {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SendSound.init) ?? .button
    }

    /// Read from disk once and kept in memory, so playing starts straight away.
    private static var loaded: [SendSound: NSSound] = [:]
    private static var playing: NSSound?

    /// Loads the sound ahead of time, e.g. when the overlay opens.
    func preload() {
        _ = sound
    }

    func play() {
        Self.playing?.stop()
        Self.playing = sound
        Self.playing?.play()
    }

    private var sound: NSSound? {
        if let sound = Self.loaded[self] { return sound }
        guard self != .off, let url = Bundle.main.url(forResource: rawValue, withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: false)
        Self.loaded[self] = sound
        return sound
    }
}
