import SwiftUI

/// Under a recording: its frames along a strip to drag through, the kept frames marked on it, and Add Frame and Crop.
struct RecordingTimeline: View {
    let session: AnnotationSession
    let recording: Recording
    @Binding var isCropping: Bool
    /// The kept frame under the pointer, and the one a drag has snapped to.
    @State private var hoveredFrame: Int?
    @State private var snappedFrame: Int?

    private static let stripHeight: CGFloat = 44
    /// How close, in points, the pointer has to be to a kept frame to pick it.
    private static let snapDistance: CGFloat = 12

    var body: some View {
        HStack(spacing: 10) {
            strip
            Text(String(format: "%.2fs", recording.seconds(recording.times[session.position])))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
            Button(action: session.toggleKeep) {
                addFrameLabel
                    .frame(minWidth: 128)
            }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(!session.canAnnotate || isCropping)
            .tooltip(session.frameIndex == nil
                ? "Add this frame to the image you send, up to \(AnnotationSession.maxFrames)"
                : "Remove this frame and its markers", shortcut: "Space")
            Button {
                session.selectedID = nil
                isCropping.toggle()
            } label: {
                Label(isCropping ? "Done" : "Crop", systemImage: "crop")
            }
            .buttonStyle(CapsuleButtonStyle(isProminent: isCropping))
            .tooltip(isCropping ? "Keep this part of the screen" : "Choose the part of the screen to keep", shortcut: isCropping ? "↩" : nil)
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// "Add Frame" with its Space key, or once the frame is added, a check in the marker colour like its pin.
    @ViewBuilder private var addFrameLabel: some View {
        if session.frameIndex == nil {
            HStack(spacing: 6) {
                Label("Add Frame", systemImage: "plus")
                Text("Space")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6)))
            }
        } else {
            Label {
                Text("Added")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color(nsColor: session.style.color))
            }
        }
    }

    private var strip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(session.thumbnails.indices, id: \.self) { index in
                        Image(decorative: session.thumbnails[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(session.thumbnails.count), height: Self.stripHeight)
                            .clipped()
                    }
                }
                .frame(width: width, height: Self.stripHeight, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // The frame on screen. On a kept frame it starts below that frame's number rather than across it.
                let playheadTop: CGFloat = session.frameIndex == nil ? -3 : 2 + 20 * 1.2
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: Self.stripHeight + 3 - playheadTop)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: position(of: recording.seconds(recording.times[session.position]), in: width) - 1.5, y: playheadTop)

                // Kept frames: a line in the marker colour with the frame's number. The one under the pointer,
                // or on screen, stands out.
                ForEach(Array(session.frames.enumerated()), id: \.offset) { index, _ in
                    let x = keptPosition(index, in: width)
                    let isHighlighted = index == hoveredFrame || index == snappedFrame || index == session.frameIndex
                    Rectangle()
                        .fill(Color(nsColor: session.style.color))
                        .frame(width: isHighlighted ? 3 : 2, height: Self.stripHeight)
                        .offset(x: x - (isHighlighted ? 1.5 : 1))
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(nsColor: session.style.color)))
                        .overlay(Circle().strokeBorder(.white, lineWidth: index == session.frameIndex ? 2 : 0))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .scaleEffect(isHighlighted ? 1.2 : 1)
                        .offset(x: x - 10, y: 2)
                }
                .animation(.snappy(duration: 0.15), value: hoveredFrame)
                .animation(.snappy(duration: 0.15), value: session.frameIndex)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrub(at: $0.location.x, in: width, exact: false) }
                    .onEnded { value in
                        scrub(at: value.location.x, in: width, exact: true)
                        snappedFrame = nil
                    }
            )
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    hoveredFrame = keptFrame(near: location.x, in: width)
                } else {
                    hoveredFrame = nil
                }
            }
            .pointerStyle(hoveredFrame != nil || snappedFrame != nil ? .link : .default)
        }
        .frame(height: Self.stripHeight)
    }

    /// Moves along the timeline, snapping onto a kept frame when the pointer is close to one.
    private func scrub(at x: CGFloat, in width: CGFloat, exact: Bool) {
        if let index = keptFrame(near: x, in: width) {
            if snappedFrame != index {
                snappedFrame = index
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            session.showKeptFrame(index)
            return
        }
        snappedFrame = nil
        session.scrub(to: fraction(at: x, in: width), exact: exact)
    }

    /// The closest kept frame within snapping distance of `x`.
    private func keptFrame(near x: CGFloat, in width: CGFloat) -> Int? {
        session.frames.indices
            .map { (index: $0, distance: abs(keptPosition($0, in: width) - x)) }
            .filter { $0.distance <= Self.snapDistance }
            .min { $0.distance < $1.distance }?
            .index
    }

    private func keptPosition(_ index: Int, in width: CGFloat) -> CGFloat {
        position(of: session.frames[index].time.map(recording.seconds) ?? 0, in: width)
    }

    private func position(of seconds: Double, in width: CGFloat) -> CGFloat {
        recording.duration > 0 ? width * seconds / recording.duration : 0
    }

    private func fraction(at x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}
