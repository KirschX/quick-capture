import AppKit

/// The menu bar icon: the app icon's window with a pin on its corner, as a template image so it takes the menu bar's colour.
let menuBarIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 19, height: 15), flipped: true) { _ in
        let window = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 3.25, width: 14.5, height: 11), xRadius: 3, yRadius: 3)
        window.lineWidth = 1.5
        window.stroke()
        // Title bar.
        NSGraphicsContext.saveGraphicsState()
        window.addClip()
        NSRect(x: 0, y: 0, width: 16, height: 6.25).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Pin, with a clear ring cut into the window around it.
        let pin = NSPoint(x: 15.25, y: 3.75)
        NSGraphicsContext.current!.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: pin.x - 4.75, y: pin.y - 4.75, width: 9.5, height: 9.5)).fill()
        NSGraphicsContext.current!.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: pin.x - 3.5, y: pin.y - 3.5, width: 7, height: 7)).fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Show & Tell"
    return image
}()
