import CoreGraphics
import Foundation

/// One numbered piece of feedback: a pin or a box, in window points (top-left origin).
struct Marker: Identifiable {
    enum Shape {
        case pin(CGPoint)
        case box(CGRect)

        /// Moved by `delta`, kept inside `bounds`.
        func offset(by delta: CGSize, within bounds: CGRect) -> Shape {
            switch self {
            case .pin(let point):
                return .pin(CGPoint(x: point.x + delta.width, y: point.y + delta.height).clamped(to: bounds))
            case .box(let rect):
                // Clamp the box's origin so the whole box stays inside.
                let origins = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - rect.width, height: bounds.height - rect.height)
                return .box(CGRect(
                    origin: CGPoint(x: rect.minX + delta.width, y: rect.minY + delta.height).clamped(to: origins),
                    size: rect.size
                ))
            }
        }
    }

    /// The box corners that can be dragged to resize. The top-left holds the number badge, which moves the box.
    enum Corner: CaseIterable {
        case topRight, bottomLeft, bottomRight

        func point(of rect: CGRect) -> CGPoint {
            switch self {
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        /// The corner that stays put while this one is dragged.
        func anchor(of rect: CGRect) -> CGPoint {
            switch self {
            case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
            }
        }
    }

    var id = UUID()
    var shape: Shape
    var note = ""
}

/// Saved as `{kind, rect, note}`, with a pin's point stored as a zero-size rect.
extension Marker: Codable {
    private enum CodingKeys: String, CodingKey { case kind, rect, note }
    private enum Kind: String, Codable { case pin, box }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rect = try container.decode(CGRect.self, forKey: .rect)
        shape = try container.decode(Kind.self, forKey: .kind) == .pin ? .pin(rect.origin) : .box(rect)
        note = try container.decode(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch shape {
        case .pin(let point):
            try container.encode(Kind.pin, forKey: .kind)
            try container.encode(CGRect(origin: point, size: .zero), forKey: .rect)
        case .box(let rect):
            try container.encode(Kind.box, forKey: .kind)
            try container.encode(rect, forKey: .rect)
        }
        try container.encode(note, forKey: .note)
    }
}

extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
