import SwiftUI

/// A note in a speech-bubble shape whose tail points at its marker. It's a solid card with a shadow,
/// so it stands out from busy windows.
struct NoteBubble: ViewModifier {
    static let width: CGFloat = 280

    /// The side the tail comes out of.
    let edge: Edge
    /// Where along that edge the tail sits, from its top (side edges) or left (top and bottom edges).
    let tailOffset: CGFloat

    func body(content: Content) -> some View {
        let shape = CalloutShape(edge: edge, tailOffset: tailOffset)
        content
            .font(.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .padding(Edge.Set(edge), CalloutShape.tailLength)
            .frame(width: Self.width)
            .background(.ultraThickMaterial, in: shape)
            .overlay { shape.stroke(.primary.opacity(0.15), lineWidth: 0.5) }
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

extension View {
    func noteBubble(edge: Edge, tailOffset: CGFloat) -> some View {
        modifier(NoteBubble(edge: edge, tailOffset: tailOffset))
    }
}

/// A rounded rectangle with a small triangle on one edge.
nonisolated private struct CalloutShape: Shape {
    static let tailLength: CGFloat = 7
    let edge: Edge
    let tailOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let halfBase: CGFloat = 7
        let length = Self.tailLength
        var body = rect
        switch edge {
        case .leading: body.origin.x += length; body.size.width -= length
        case .trailing: body.size.width -= length
        case .top: body.origin.y += length; body.size.height -= length
        case .bottom: body.size.height -= length
        }
        let rounded = Path(roundedRect: body, cornerRadius: radius)

        // Keep the tail off the rounded corners; overlap the body by a point so there's no seam.
        let along: CGFloat
        switch edge {
        case .leading, .trailing: along = min(max(tailOffset, radius + halfBase), rect.height - radius - halfBase)
        case .top, .bottom: along = min(max(tailOffset, radius + halfBase), rect.width - radius - halfBase)
        }
        let points: [CGPoint] = switch edge {
        case .leading: [CGPoint(x: body.minX + 1, y: along - halfBase), CGPoint(x: rect.minX, y: along), CGPoint(x: body.minX + 1, y: along + halfBase)]
        case .trailing: [CGPoint(x: body.maxX - 1, y: along - halfBase), CGPoint(x: rect.maxX, y: along), CGPoint(x: body.maxX - 1, y: along + halfBase)]
        case .top: [CGPoint(x: along - halfBase, y: body.minY + 1), CGPoint(x: along, y: rect.minY), CGPoint(x: along + halfBase, y: body.minY + 1)]
        case .bottom: [CGPoint(x: along - halfBase, y: body.maxY - 1), CGPoint(x: along, y: rect.maxY), CGPoint(x: along + halfBase, y: body.maxY - 1)]
        }
        var tail = Path()
        tail.addLines(points)
        tail.closeSubpath()
        // A true union, so the tail joins the body without a seam whichever way it's wound.
        return rounded.union(tail)
    }
}

/// Multi-line note field: Return copies (handled by `OverlayPanel`), ⇧↩ adds a line, Esc leaves the note, Tab also clears its selection.
struct NoteEditor: View {
    @Binding var note: String
    var focus: FocusState<OverlayView.Focus?>.Binding

    var body: some View {
        // An invisible copy of the text sets the size (up to 7 lines, then it scrolls);
        // the editor and placeholder are laid over it, so the bubble fits the note.
        Text(note.isEmpty ? " " : note + " ")
            .lineLimit(7)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text("코멘트 입력 (↩ 복사 · ⇧↩ 줄바꿈)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .focused(focus, equals: .note)
            }
    }
}
