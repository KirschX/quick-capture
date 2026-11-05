#if DEBUG
import AppKit

/// Debug builds only: plays a scripted take for recording the README demo (`scripts/record-demo.sh`).
/// It first lays out Claude and the demo page side by side; then the take has its markers added to a
/// capture of the page through the real annotation session. The operator clicks Copy & Open Claude,
/// pastes the image with ⌘V and submits it.
enum DemoTake {
    static let notification = Notification.Name("com.oralart.showandtell.dev.take")
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Where the overlay shows the screenshot, set by `OverlayView`, so window points can be found on screen.
    struct Shown {
        var rect: CGRect
        var zoom: CGFloat
        var screen: CGRect
    }

    static var shown: Shown?
    static var sendButton: CGRect?

    private struct Take: Decodable {
        let windowSize: CGSize
        let markers: [Marker]
    }

    /// What the script asks for, from the notification's user info.
    private struct Request {
        /// Claude goes in the left half, the page in the right; global points, top-left origin.
        var layout: CGRect
        var browser: String
        /// The page's title, to find its window.
        var title: String
        /// Without a take, it only lays out the windows.
        var take: URL?
        /// A file each step's time is appended to, for cutting the recording.
        var times: URL
    }

    static func listen() {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard let info = note.userInfo as? [String: String],
                  let layout = info["layout"]?.split(separator: ",").compactMap({ Double($0) }), layout.count == 4,
                  let browser = info["browser"], let title = info["title"], let take = info["take"],
                  let times = info["times"] else { return }
            let request = Request(layout: CGRect(x: layout[0], y: layout[1], width: layout[2], height: layout[3]),
                                  browser: browser, title: title, take: take.isEmpty ? nil : URL(filePath: take),
                                  times: URL(filePath: times))
            Task { @MainActor in await play(request) }
        }
    }

    private static var isPlaying = false

    private static func play(_ request: Request) async {
        guard !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }
        let times = request.times
        try? Data().write(to: times)
        log("received", to: times)
        guard arrange(request) else {
            log("failed couldn't find the Claude window, or a \(request.browser) window titled \"\(request.title)\"", to: times)
            return
        }
        log("arranged", to: times)
        guard let url = request.take else { return }
        guard let data = try? Data(contentsOf: url), let take = try? JSONDecoder().decode(Take.self, from: data) else {
            log("failed couldn't read the take", to: times)
            return
        }
        shown = nil
        sendButton = nil
        log("armed", to: times)
        // The operator activates Show & Tell with its real shortcut, visible in the recording.
        for _ in 0..<1200 where shown == nil || CaptureCoordinator.shared.demoSession == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard shown != nil, let session = CaptureCoordinator.shared.demoSession else {
            log("failed the overlay didn't open", to: times)
            return
        }
        log("start", to: times)
        guard abs(session.capture.frame.width - take.windowSize.width) < 1,
              abs(session.capture.frame.height - take.windowSize.height) < 1 else {
            log("failed demo window size doesn't match the take", to: times)
            return
        }
        // Let the overlay finish fading in.
        try? await Task.sleep(for: .seconds(0.8))

        for marker in take.markers {
            switch marker.shape {
            case .pin(let point):
                await move(to: point)
            case .box(let rect):
                await move(to: rect.origin)
                // Animate the same draft the drag gesture draws, without relying on injected mouse events.
                for step in 1...60 {
                    let progress = CGFloat(step) / 60
                    post(.mouseMoved, at: onScreen(CGPoint(x: rect.minX + rect.width * progress,
                                                           y: rect.minY + rect.height * progress)))
                    session.draft = CGRect(origin: rect.origin,
                                           size: CGSize(width: rect.width * progress, height: rect.height * progress))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                session.draft = nil
            }
            guard session.add(marker.shape) != nil else {
                log("failed couldn't add a marker", to: times)
                return
            }
            try? await Task.sleep(for: .seconds(0.3))
            for character in marker.note {
                session.markers[session.markers.count - 1].note.append(character)
                try? await Task.sleep(for: .milliseconds(65))
            }
            try? await Task.sleep(for: .seconds(2.5))
            session.selectedID = nil
            try? await Task.sleep(for: .seconds(0.3))
        }

        if let button = sendButton, let shown {
            await move(to: CGPoint(x: (button.midX - shown.rect.minX) / shown.zoom,
                                   y: (button.midY - shown.rect.minY) / shown.zoom))
        }
        log("annotated", to: times)
        // Keep the real toolbar visible until the operator clicks Copy & Open Claude.
        for _ in 0..<600 where CaptureCoordinator.shared.demoSession != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard CaptureCoordinator.shared.demoSession == nil, CaptureCoordinator.shared.demoIsSending else {
            log("failed the annotation wasn't copied for Claude", to: times)
            return
        }
        log("copied", to: times)

        // Wait for the image to be copied and Claude opened; the operator pastes it and submits.
        for _ in 0..<100 where CaptureCoordinator.shared.demoIsSending {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !CaptureCoordinator.shared.demoIsSending else {
            log("failed copying for Claude timed out", to: times)
            return
        }
        log("ready", to: times)
    }

    // MARK: Windows

    /// Puts Claude in the left half of the layout and the page in the right, and brings the page to the front,
    /// since the capture is of the front window. Done with Accessibility, which Show & Tell has for finding the front window.
    private static func arrange(_ request: Request) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let browser = apps.first(where: { $0.localizedName == request.browser }),
              let claude = apps.first(where: { $0.bundleIdentifier == claudeBundleID }),
              let page = pageWindow(of: browser, titled: request.title),
              let claudeWindow = mainWindow(of: claude) else { return false }
        let layout = request.layout
        let gap: CGFloat = 24
        let half = (layout.width - gap) / 2
        place(claudeWindow, in: CGRect(x: layout.minX, y: layout.minY, width: half, height: layout.height))
        place(page, in: CGRect(x: layout.minX + half + gap, y: layout.minY, width: half, height: layout.height))
        // Start with only the two demo apps visible, including behind the translucent overlay.
        for app in apps where app.activationPolicy == .regular
            && app.processIdentifier != browser.processIdentifier
            && app.processIdentifier != claude.processIdentifier
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.hide()
        }
        AXUIElementPerformAction(claudeWindow, kAXRaiseAction as CFString)
        claude.activate()
        AXUIElementPerformAction(page, kAXRaiseAction as CFString)
        browser.activate()
        return true
    }

    private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// Use the regular browser window, including its tabs and address bar.
    private static func pageWindow(of browser: NSRunningApplication, titled pageTitle: String) -> AXUIElement? {
        let all = windows(of: browser)
        return all.first { title(of: $0).hasPrefix(pageTitle + " - " + (browser.localizedName ?? "")) }
    }

    /// Claude has other, hidden windows; this is the one in use.
    private static func mainWindow(of app: NSRunningApplication) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXMainWindowAttribute as CFString, &value)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return value as? String ?? ""
    }

    private static func place(_ window: AXUIElement, in frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let size = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        }
    }

    // MARK: Input

    /// A point in window points, in global display coordinates (top-left origin) as the overlay shows it.
    private static func onScreen(_ point: CGPoint) -> CGPoint {
        guard let shown else { return point }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: shown.screen.minX + shown.rect.minX + point.x * shown.zoom,
                       y: primaryHeight - shown.screen.maxY + shown.rect.minY + point.y * shown.zoom)
    }

    /// Glides the pointer there, easing in and out, like a hand on a trackpad.
    private static func move(to point: CGPoint) async {
        let start = CGEvent(source: nil)?.location ?? .zero
        let end = onScreen(point)
        let steps = 30
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let location = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
            post(.mouseMoved, at: location)
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func post(_ type: CGEventType, at location: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func log(_ step: String, to times: URL) {
        guard let handle = try? FileHandle(forWritingTo: times) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(step) \(Date().timeIntervalSince1970)\n".utf8))
        try? handle.close()
    }
}
#endif
