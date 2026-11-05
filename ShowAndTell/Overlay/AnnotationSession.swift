import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// What's being annotated, with selection and undo: one window screenshot, or frames kept from a screen recording.
@Observable
final class AnnotationSession {
    /// One image with its markers. A screenshot is a single frame; a recording has one per moment kept.
    struct Frame {
        /// Where in the recording; nil for a screenshot.
        var time: CMTime?
        /// The whole window, or the whole display for a recording.
        var image: CGImage
        var markers: [Marker] = []
    }

    static let maxFrames = 6

    /// The window, or for a recording the display. Its image is whichever frame was shown first.
    let source: CapturedWindow
    /// Set for a screen recording.
    let recording: Recording?
    var frames: [Frame] {
        didSet { hasChanges = true }
    }
    /// The part of every frame that's shown and sent, in source points. The whole window for a screenshot.
    private(set) var crop: CGRect
    /// What's on screen: the cropped current image, positioned on screen like a window.
    private(set) var capture: CapturedWindow
    /// The whole image on screen: a kept frame, or for a recording any frame along the timeline.
    private(set) var image: CGImage
    /// The recording frame on screen, kept or not.
    private(set) var time: CMTime?
    /// The frame the timeline points at. It moves straight away; `image` follows once it's decoded.
    private(set) var position = 0
    /// Small frames along the timeline, filled in once decoded.
    private(set) var thumbnails: [CGImage] = []

    var selectedID: UUID?
    /// Box being dragged out, before it becomes a marker.
    var draft: CGRect?
    /// Set once the capture is saved, or when it was reopened from history.
    var savedID: UUID?
    /// Colour and size of every marker on this capture; also becomes the default for the next one.
    var style: MarkerStyle {
        didSet {
            MarkerStyle.lastUsed = style
            hasChanges = true
        }
    }
    /// Whether anything changed since this capture was opened, so unchanged ones aren't re-saved.
    private(set) var hasChanges = false

    /// Earlier and undone states, for ⌘Z and ⇧⌘Z, with the recording time each change was made at.
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// One frame is decoded at a time, then the newest one asked for meanwhile, so the picture keeps up with
    /// dragging or a held arrow key and stops when they do.
    @ObservationIgnored private var isDecoding = false
    @ObservationIgnored private var pending: (index: Int, exact: Bool)?
    /// Bumped when a frame is shown without decoding, so a decode that was already running doesn't replace it.
    @ObservationIgnored private var generation = 0

    private struct Snapshot {
        var frames: [Frame]
        var crop: CGRect
        var time: CMTime?
    }

    /// A window screenshot.
    init(capture: CapturedWindow, markers: [Marker] = [], savedID: UUID? = nil, style: MarkerStyle = .lastUsed) {
        source = capture
        recording = nil
        frames = [Frame(image: capture.image, markers: markers)]
        crop = CGRect(origin: .zero, size: capture.frame.size)
        self.capture = capture
        image = capture.image
        self.savedID = savedID
        self.style = style
    }

    /// A screen recording, showing the frame at `time` first; `display.image` is that frame, uncropped.
    init(recording: Recording, display: CapturedWindow, crop: CGRect, frames: [Frame], time: CMTime,
         savedID: UUID? = nil, style: MarkerStyle = .lastUsed) {
        source = display
        self.recording = recording
        self.frames = frames
        self.crop = crop
        capture = display
        image = display.image
        self.time = time
        position = recording.times.firstIndex(of: time) ?? 0
        self.savedID = savedID
        self.style = style
        updateCapture()
        Task {
            let thumbnails = await recording.thumbnails(count: 16, height: 80)
            self.thumbnails = thumbnails
        }
    }

    var bounds: CGRect { CGRect(origin: .zero, size: capture.frame.size) }

    // MARK: Frames

    /// The kept frame on screen: always the one for a screenshot; for a recording, nil between kept frames.
    var frameIndex: Int? {
        guard recording != nil else { return 0 }
        return frames.firstIndex { $0.time == time }
    }

    /// The markers on the frame on screen. Adding one to a recording frame that isn't kept keeps it.
    var markers: [Marker] {
        get { frameIndex.map { frames[$0].markers } ?? [] }
        set {
            guard let index = frameIndex ?? keepShownFrame() else { return }
            frames[index].markers = newValue
        }
    }

    /// Whether a marker can go on the frame on screen: a recording keeps at most `maxFrames`.
    var canAnnotate: Bool { frameIndex != nil || frames.count < Self.maxFrames }

    /// Markers are numbered across all frames, so the number of this frame's first marker.
    var firstNumber: Int {
        frames[..<(frameIndex ?? 0)].reduce(0) { $0 + $1.markers.count } + 1
    }

    var hasMarkers: Bool { frames.contains { !$0.markers.isEmpty } }

    /// Kept in Recent on closing: anything with markers, and a recording with frames picked from it.
    var isWorthSaving: Bool { hasMarkers || (recording != nil && !frames.isEmpty) }

    /// What's sent: the kept frames, or with none kept, the recording frame on screen.
    var framesToSend: [Frame] {
        if recording != nil && frames.isEmpty { return [Frame(time: time, image: image)] }
        return frames
    }

    /// Keeps the recording frame on screen, or lets it go (with its markers) if it's already kept.
    func toggleKeep() {
        guard recording != nil else { return }
        if let index = frameIndex {
            recordUndo(frames)
            frames.remove(at: index)
            selectedID = nil
        } else if frames.count < Self.maxFrames {
            recordUndo(frames)
            keepShownFrame()
        }
    }

    @discardableResult
    private func keepShownFrame() -> Int? {
        guard let recording, let time, frames.count < Self.maxFrames else { return nil }
        // Stay on the frame being kept, even if a rough one from dragging is showing and the exact one is on its way.
        position = recording.times.firstIndex(of: time) ?? position
        pending = nil
        generation += 1
        let index = frames.firstIndex { $0.time.map { $0 > time } ?? false } ?? frames.count
        frames.insert(Frame(time: time, image: image), at: index)
        return index
    }

    /// Steps one recording frame earlier or later.
    func step(by offset: Int) {
        guard let recording else { return }
        show(index: min(max(position + offset, 0), recording.times.count - 1), exact: true)
    }

    /// Moves to a point along the timeline, 0...1. While dragging, `exact` is false for speed.
    func scrub(to fraction: Double, exact: Bool) {
        guard let recording else { return }
        show(index: recording.index(near: fraction * recording.duration), exact: exact)
    }

    /// Shows a kept frame, straight away since it's already decoded.
    func showKeptFrame(_ index: Int) {
        guard let recording, frames.indices.contains(index), let time = frames[index].time,
              let position = recording.times.firstIndex(of: time) else { return }
        show(index: position, exact: true)
    }

    /// Jumps to the previous or next kept frame.
    func jumpToKeptFrame(by offset: Int) {
        guard let recording, let time else { return }
        let target = offset < 0 ? frames.last { $0.time! < time } : frames.first { $0.time! > time }
        if let target, let index = recording.times.firstIndex(of: target.time!) { show(index: index, exact: true) }
    }

    private func show(index: Int, exact: Bool) {
        guard let recording else { return }
        position = index
        let target = recording.times[index]
        if let kept = frames.first(where: { $0.time == target }) {
            pending = nil
            generation += 1
            display(kept.image, at: target)
            return
        }
        pending = (index, exact)
        decodeNext()
    }

    private func decodeNext() {
        guard !isDecoding, let recording, let (index, exact) = pending else { return }
        pending = nil
        isDecoding = true
        let generation = generation
        let target = recording.times[index]
        Task {
            let result = try? await recording.image(at: target, exact: exact)
            isDecoding = false
            if let result, generation == self.generation {
                display(result.image, at: exact ? target : result.time)
            }
            decodeNext()
        }
    }

    private func display(_ image: CGImage, at time: CMTime) {
        if time != self.time {
            selectedID = nil
            draft = nil
        }
        self.image = image
        self.time = time
        updateCapture()
    }

    // MARK: Crop

    /// The whole display, for choosing the crop.
    var sourceBounds: CGRect { CGRect(origin: .zero, size: source.frame.size) }

    /// Changes the crop, moving every marker with the image so they still point at the same things.
    func setCrop(_ rect: CGRect) {
        let new = rect.integral.intersection(sourceBounds)
        guard new != crop, new.width >= 40, new.height >= 40 else { return }
        recordUndo(frames)
        let delta = CGSize(width: crop.minX - new.minX, height: crop.minY - new.minY)
        let bounds = CGRect(origin: .zero, size: new.size)
        for index in frames.indices {
            for marker in frames[index].markers.indices {
                frames[index].markers[marker].shape = frames[index].markers[marker].shape.offset(by: delta, within: bounds)
            }
        }
        crop = new
        updateCapture()
    }

    /// The cropped image, placed where that part of the display is.
    private func updateCapture() {
        guard recording != nil else { return }
        let scale = source.pixelScale
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        capture = CapturedWindow(
            image: image.cropping(to: pixels) ?? image,
            frame: crop.offsetBy(dx: source.frame.minX, dy: source.frame.minY),
            screen: source.screen,
            appName: source.appName,
            windowTitle: source.windowTitle
        )
    }

    // MARK: Markers

    /// The marker under a point: pins and box badges first, since they're drawn on top,
    /// then the box (anywhere inside it or on its edge) that was added last.
    func marker(at point: CGPoint) -> UUID? {
        let reach = style.pinRadius + 3
        for marker in markers.reversed() {
            let badge = style.badgeCenter(of: marker.shape, within: bounds)
            if hypot(point.x - badge.x, point.y - badge.y) <= reach { return marker.id }
        }
        for marker in markers.reversed() {
            if case .box(let rect) = marker.shape, rect.insetBy(dx: -6, dy: -6).contains(point) { return marker.id }
        }
        return nil
    }

    /// A resize handle of the selected box under a point.
    func resizeHandle(at point: CGPoint) -> (UUID, Marker.Corner, CGRect)? {
        guard let selectedID, let marker = markers.first(where: { $0.id == selectedID }), case .box(let rect) = marker.shape else { return nil }
        for corner in Marker.Corner.allCases {
            let handle = corner.point(of: rect)
            if hypot(point.x - handle.x, point.y - handle.y) <= 9 { return (selectedID, corner, rect) }
        }
        return nil
    }

    @discardableResult
    func add(_ shape: Marker.Shape) -> UUID? {
        guard canAnnotate else { return nil }
        recordUndo(frames)
        let marker = Marker(shape: shape)
        markers.append(marker)
        selectedID = marker.id
        return marker.id
    }

    func remove(_ id: UUID) {
        recordUndo(frames)
        markers.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    // MARK: Undo

    /// Saves the frames as they were before a change.
    func recordUndo(_ snapshot: [Frame]) {
        undoStack.append(Snapshot(frames: snapshot, crop: crop, time: time))
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(frames: frames, crop: crop, time: previous.time))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(frames: frames, crop: crop, time: next.time))
        restore(next)
    }

    /// Goes back to a snapshot, and to the recording frame it changed so the change can be seen.
    private func restore(_ snapshot: Snapshot) {
        frames = snapshot.frames
        if snapshot.crop != crop {
            crop = snapshot.crop
            updateCapture()
        }
        if let recording, let time = snapshot.time, time != self.time, let index = recording.times.firstIndex(of: time) {
            show(index: index, exact: true)
        }
        if let selectedID, !markers.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}
