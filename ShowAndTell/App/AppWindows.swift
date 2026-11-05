import AppKit

/// Menu bar apps don't reliably come to the front when they open a window: activation can be
/// refused, or the window lands behind the app you were in. While one of Show & Tell's windows is open
/// it runs as a regular app (Dock icon, ⌘Tab), which makes activation reliable; once they're all
/// closed it goes back to menu-bar-only.
enum AppWindows {
    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// For SwiftUI windows: `open` opens it, then the window whose identifier contains `id` is brought forward.
    static func show(id: String, open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        // The window exists once SwiftUI has handled `open`.
        DispatchQueue.main.async {
            let window = NSApp.windows.first { $0.identifier?.rawValue.contains(id) == true }
                ?? NSApp.windows.last { $0.isVisible && $0.styleMask.contains(.titled) }
            if let window { show(window) }
        }
    }

    /// Goes back to menu-bar-only when the last titled window closes.
    static func watchForLastWindowClosing() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // Delivered on the main queue, so the window can be used on the main actor.
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let closing, closing.styleMask.contains(.titled) else { return }
                DispatchQueue.main.async {
                    let anyOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
                    if !anyOpen { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }
}
