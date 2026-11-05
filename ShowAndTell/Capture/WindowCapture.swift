import AppKit
import ScreenCaptureKit

/// A frozen picture of one window and where it sat on screen.
struct CapturedWindow {
    let image: CGImage
    /// Window frame in global screen points, top-left origin (Core Graphics space).
    let frame: CGRect
    let screen: NSScreen
    let appName: String
    let windowTitle: String?

    /// Image pixels per window point.
    var pixelScale: CGFloat { CGFloat(image.width) / frame.width }
}

struct NoFrontWindow: Error {}

enum WindowCapture {
    /// Captures the whole display under the mouse, without the cursor, so any part of the screen can be marked.
    static func captureDisplayUnderMouse() async throws -> CapturedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw NoFrontWindow() }
        // Leave out this app's own windows, such as a toast still fading from the last copy.
        let ownApp = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = output.sdrImage else { throw NoFrontWindow() }
        let front = NSWorkspace.shared.frontmostApplication
        return CapturedWindow(image: image, frame: screen.topLeftFrame, screen: screen,
                              appName: front?.localizedName ?? "Screen", windowTitle: nil)
    }

    /// Captures the front window of the frontmost app, without its shadow or the cursor.
    static func captureFrontWindow() async throws -> CapturedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let (window, app) = frontWindow(in: content) else { throw NoFrontWindow() }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCScreenshotConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.showsCursor = false
        config.ignoreShadows = true
        config.dynamicRange = .sdr

        // Let the screenshot size itself to the complete window, including Chrome's separate
        // full-screen toolbar. The content filter's rectangle can cover only the shorter document
        // surface; using it as the output size scales the screenshot down and pads its right edge.
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard var image = output.sdrImage else { throw NoFrontWindow() }
        let frame = CGRect(origin: window.frame.origin,
                           size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        let screen = screen(containing: window.frame)
        // Full-screen windows lose their native rounded corners. Include the usable display
        // height so this also works when macOS keeps the menu bar or camera housing above them.
        if frame.width >= screen.frame.width - 1, frame.height >= screen.visibleFrame.height - 1 {
            image = try roundingCorners(of: image, radius: 12 * scale)
        }
        return CapturedWindow(
            image: image,
            frame: frame,
            screen: screen,
            appName: app.localizedName ?? window.owningApplication?.applicationName ?? "App",
            windowTitle: window.title?.isEmpty == false ? window.title : nil
        )
    }

    /// Round the source once so the overlay, exported shadow and saved capture share its outline.
    private static func roundingCorners(of image: CGImage, radius: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NoFrontWindow() }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: bounds)
        guard let rounded = context.makeImage() else { throw NoFrontWindow() }
        return rounded
    }

    /// The frontmost app's front window, as ScreenCaptureKit sees it.
    static func frontWindow(in content: SCShareableContent) -> (SCWindow, NSRunningApplication)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let windowID = frontWindowID(of: app.processIdentifier),
              let window = content.windows.first(where: { $0.windowID == windowID })
        else { return nil }
        return (window, app)
    }

    /// The app's frontmost normal window containing its focused window's centre.
    /// Chrome puts a separate, narrow toolbar window first in full screen; capturing it
    /// squeezes the document into a toolbar-height image.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let center = focusedWindowCenter(of: pid),
              let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 40, rect.height > 40,
                  rect.contains(center),
                  let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return id
        }
        return nil
    }

    /// Accessibility identifies the document window, rather than its auxiliary window-server surfaces.
    private static func focusedWindowCenter(of pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
    }

    static func screen(containing frame: CGRect) -> NSScreen {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.topLeftFrame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

extension NSScreen {
    /// The screen's frame in top-left-origin global points, matching window frames from the window server.
    var topLeftFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
