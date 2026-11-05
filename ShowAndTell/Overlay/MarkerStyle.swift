import AppKit

/// How markers look: colour and size. Draws them for both the live overlay and the exported image,
/// so the two always match.
struct MarkerStyle: Codable, Equatable {
    enum Tint: String, Codable, CaseIterable {
        case red, blue, green, pink

        var color: NSColor {
            switch self {
            case .red: NSColor(srgbRed: 0.90, green: 0.18, blue: 0.20, alpha: 1)
            case .blue: NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)
            case .green: NSColor(srgbRed: 0.10, green: 0.65, blue: 0.32, alpha: 1)
            case .pink: NSColor(srgbRed: 0.91, green: 0.30, blue: 0.55, alpha: 1)
            }
        }

        var name: String { rawValue.capitalized }
    }

    /// Medium is the default. Raw values start at 1 because saved captures store them, and 0 was a smaller size that's gone.
    enum Size: Int, Codable, CaseIterable {
        case small = 1, medium, large

        var factor: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.25
            }
        }
    }

    var tint = Tint.red
    var size = Size.medium

    var color: NSColor { tint.color }
    var pinRadius: CGFloat { 13 * size.factor }
    var boxLineWidth: CGFloat { 3 * size.factor }

    /// One size step up or down, stopping at the ends.
    func resized(by step: Int) -> MarkerStyle {
        var style = self
        let index = Size.allCases.firstIndex(of: size)! + step
        style.size = Size.allCases[min(max(index, 0), Size.allCases.count - 1)]
        return style
    }

    /// The style used last, so a new capture starts the way the previous one ended.
    static var lastUsed: MarkerStyle {
        get {
            UserDefaults.standard.data(forKey: "markerStyle").flatMap { try? JSONDecoder().decode(MarkerStyle.self, from: $0) } ?? MarkerStyle()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "markerStyle")
        }
    }

    /// Where a marker's number badge sits: on a pin's point or a box's top-left corner,
    /// nudged inwards so the whole badge stays inside `bounds` (the screenshot) and never gets cut off.
    func badgeCenter(of shape: Marker.Shape, within bounds: CGRect) -> CGPoint {
        let point: CGPoint = switch shape {
        case .pin(let center): center
        case .box(let rect): CGPoint(x: rect.minX, y: rect.minY)
        }
        // Room for the hover lift and the badge's shadow too.
        let inset = pinRadius + 3
        return point.clamped(to: bounds.insetBy(dx: inset, dy: inset))
    }

    // MARK: Drawing

    /// Paints into a top-left-origin context where one window point is `scale` units.
    /// `hoveredID` gives the marker under the pointer a slight lift; exports leave it out.
    /// Numbers start at `firstNumber`, since a recording numbers markers across its frames.
    func paint(_ markers: [Marker], within bounds: CGRect, selectedID: UUID?, hoveredID: UUID? = nil, draft: CGRect?, scale: CGFloat,
               firstNumber: Int = 1, in cg: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Boxes first so pins and badges sit on top of their outlines.
        for (index, marker) in markers.enumerated() {
            if case .box(let rect) = marker.shape {
                let selected = marker.id == selectedID, hovered = marker.id == hoveredID
                paintBox(rect.scaled(scale), scale: scale, selected: selected, hovered: hovered)
                paintBadge(firstNumber + index, at: badgeCenter(of: marker.shape, within: bounds).scaled(scale), scale: scale, selected: selected, hovered: hovered)
            }
        }
        for (index, marker) in markers.enumerated() {
            if case .pin = marker.shape {
                paintBadge(firstNumber + index, at: badgeCenter(of: marker.shape, within: bounds).scaled(scale), scale: scale, selected: marker.id == selectedID, hovered: marker.id == hoveredID)
            }
        }
        if let draft {
            paintBox(draft.scaled(scale), scale: scale, selected: false, hovered: false)
        }
    }

    private func paintBox(_ rect: CGRect, scale: CGFloat, selected: Bool, hovered: Bool) {
        color.withAlphaComponent(hovered ? 0.16 : 0.08).setFill()
        rect.fill()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = (hovered ? boxLineWidth + 1 : boxLineWidth) * scale
        color.setStroke()
        path.stroke()
        if selected {
            for corner in Marker.Corner.allCases {
                paintHandle(at: corner.point(of: rect), scale: scale)
            }
        }
    }

    /// A soft white dot for dragging a box corner.
    private func paintHandle(at center: CGPoint, scale: CGFloat) {
        let radius = 6 * scale
        let handle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -1 * scale)
        shadow.set()
        NSColor.white.setFill()
        handle.fill()
        NSGraphicsContext.restoreGraphicsState()

        handle.lineWidth = 1.5 * scale
        color.setStroke()
        handle.stroke()
    }

    /// Expects a flipped NSGraphicsContext to be current.
    func paintBadge(_ number: Int, at center: CGPoint, scale: CGFloat, selected: Bool, hovered: Bool = false) {
        let radius = (hovered ? pinRadius + 1.5 : pinRadius) * scale
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(hovered ? 0.55 : 0.45)
        shadow.shadowBlurRadius = (hovered ? 5 : 3) * scale
        shadow.shadowOffset = NSSize(width: 0, height: -1 * scale)
        shadow.set()
        color.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        circle.lineWidth = (selected ? 3 : 2) * size.factor * scale
        NSColor.white.setStroke()
        circle.stroke()

        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 13 * size.factor * scale, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        text.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    }
}

extension CGRect {
    func scaled(_ s: CGFloat) -> CGRect {
        CGRect(x: minX * s, y: minY * s, width: width * s, height: height * s)
    }
}

extension CGPoint {
    func scaled(_ s: CGFloat) -> CGPoint {
        CGPoint(x: x * s, y: y * s)
    }
}
