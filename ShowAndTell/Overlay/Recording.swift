import AVFoundation
import CoreGraphics

struct EmptyRecording: Error {}

/// A mouse click during a recording, saved as `{time, x, y, button, release: {time, x, y}}`: seconds into the movie,
/// and display points from the top left. `release` is missing if the button was still held when recording stopped.
nonisolated struct Click: Codable {
    enum Button: String, Codable { case left, right, other }

    /// When and where the button was let go: somewhere else after a drag.
    struct Release: Codable {
        var time: Double
        var x: CGFloat
        var y: CGFloat
    }

    var time: Double
    var x: CGFloat
    var y: CGFloat
    var button: Button
    var release: Release?
}

/// A click as one frame shows it: held down where it was pressed, or let go where it was released.
nonisolated struct ShownClick {
    var point: CGPoint
    var button: Click.Button
    var isDown: Bool
}

/// A screen recording to pick frames from: the time of every frame, and the image at any of them, with recent
/// clicks drawn on. It never changes after opening, and frames are decoded off the main thread.
nonisolated final class Recording: @unchecked Sendable {
    let url: URL
    /// Every frame's presentation time, in order. Screen recordings only add a frame when something
    /// changes, so these are uneven, and stepping goes by index rather than by a fixed interval.
    let times: [CMTime]
    let clicks: [Click]
    /// The recorded display's size in points, to draw clicks at the right size.
    private let displaySize: CGSize
    /// A temporary recording that hasn't been kept is removed once nothing uses it.
    private let deletesFile: Bool
    /// Exact frames, for showing and sending.
    private let exactGenerator: AVAssetImageGenerator
    /// The nearest quick-to-decode frame, while dragging along the timeline.
    private let roughGenerator: AVAssetImageGenerator
    /// Small frames for the timeline.
    private let thumbnailGenerator: AVAssetImageGenerator

    private init(url: URL, asset: AVURLAsset, times: [CMTime], clicks: [Click], displaySize: CGSize, deletesFile: Bool) {
        self.url = url
        self.times = times
        self.clicks = clicks
        self.displaySize = displaySize
        self.deletesFile = deletesFile
        exactGenerator = AVAssetImageGenerator(asset: asset)
        exactGenerator.requestedTimeToleranceBefore = .zero
        exactGenerator.requestedTimeToleranceAfter = .zero
        roughGenerator = AVAssetImageGenerator(asset: asset)
        thumbnailGenerator = AVAssetImageGenerator(asset: asset)
    }

    /// Reads every frame's time without decoding any of them.
    static func open(_ url: URL, clicks: [Click], displaySize: CGSize, deletesFile: Bool) async throws -> Recording {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EmptyRecording() }
        let times = try await Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            var times: [CMTime] = []
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if time.isValid && CMSampleBufferGetNumSamples(sample) > 0 { times.append(time) }
            }
            return times.sorted()
        }.value
        guard !times.isEmpty else { throw EmptyRecording() }
        return Recording(url: url, asset: asset, times: times, clicks: clicks, displaySize: displaySize, deletesFile: deletesFile)
    }

    deinit {
        if deletesFile { try? FileManager.default.removeItem(at: url) }
    }

    /// Seconds from the first frame.
    func seconds(_ time: CMTime) -> Double {
        (time - times[0]).seconds
    }

    var duration: Double { seconds(times[times.count - 1]) }

    /// The frame closest to a point in the recording, in seconds from the start.
    func index(near seconds: Double) -> Int {
        let target = times[0] + CMTime(seconds: seconds, preferredTimescale: times[0].timescale)
        let after = times.partitioningIndex { $0 >= target }
        if after == 0 { return 0 }
        if after == times.count { return times.count - 1 }
        return (target - times[after - 1]) <= (times[after] - target) ? after - 1 : after
    }

    /// The image at `time`, with the time of the frame it actually is.
    @concurrent func image(at time: CMTime, exact: Bool) async throws -> (image: CGImage, time: CMTime) {
        let result = try await (exact ? exactGenerator : roughGenerator).image(at: time)
        return (drawingClicks(on: result.image, at: result.actualTime), result.actualTime)
    }

    /// How long a click stays on the frames after it.
    private static let clickShown = 0.5

    /// The clicks shown on the frame at `time`: buttons held down then, and releases in the half second before it,
    /// or since the frame before it, since a click that changes nothing on screen doesn't add a frame of its own.
    /// Times are a frame ahead, in case the click times are slightly off.
    func clicks(at time: CMTime) -> [ShownClick] {
        let index = times.partitioningIndex { $0 >= time }
        let previous = index > 0 ? times[index - 1].seconds : -Double.infinity
        let now = time.seconds + 1.0 / 60
        return clicks.compactMap { click in
            guard click.time <= now else { return nil }
            guard let release = click.release, release.time <= now else {
                return ShownClick(point: CGPoint(x: click.x, y: click.y), button: click.button, isDown: true)
            }
            guard release.time > previous || release.time >= now - Self.clickShown else { return nil }
            return ShownClick(point: CGPoint(x: release.x, y: release.y), button: click.button, isDown: false)
        }
    }

    /// Draws a ring where each recent click was, or returns the image as it is when there aren't any.
    private func drawingClicks(on image: CGImage, at time: CMTime) -> CGImage {
        let shown = clicks(at: time)
        guard !shown.isEmpty, displaySize.width > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        let scale = CGFloat(image.width) / displaySize.width
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // White on dark rather than the marker colour, so a click isn't mistaken for a pin. Filled while held down,
        // hollow once let go; right clicks are dashed.
        for click in shown {
            let radius = 16 * scale
            let ring = CGRect(x: click.point.x * scale - radius, y: height - click.point.y * scale - radius,
                              width: radius * 2, height: radius * 2)
            if click.isDown {
                context.setFillColor(CGColor(gray: 0, alpha: 0.25))
                context.fillEllipse(in: ring)
            }
            context.setLineDash(phase: 0, lengths: click.button == .right ? [5 * scale, 3 * scale] : [])
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
            context.setLineWidth(5 * scale)
            context.strokeEllipse(in: ring)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(2.5 * scale)
            context.strokeEllipse(in: ring)
        }
        return context.makeImage() ?? image
    }

    /// Small images spread evenly in time through the recording, for the timeline.
    @concurrent func thumbnails(count: Int, height: CGFloat) async -> [CGImage] {
        thumbnailGenerator.maximumSize = CGSize(width: 0, height: height)
        // By time, matching the timeline: the middle of each slot.
        let picks = (0..<count).map { times[index(near: duration * (Double($0) + 0.5) / Double(count))] }
        var images: [CGImage] = []
        for time in picks {
            if let image = try? await thumbnailGenerator.image(at: time).image { images.append(image) }
        }
        return images
    }
}

nonisolated private extension Array {
    /// The first index where `predicate` holds, for an array where it's false then true.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
