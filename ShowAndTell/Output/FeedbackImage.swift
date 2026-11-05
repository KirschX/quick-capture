import AppKit

/// The annotated screenshot. A screen capture is cropped to the marked region and its notes are copied as text beside
/// it; a recording's kept frames go in a grid with the numbered notes in a card underneath.
enum FeedbackImage {
    /// Size of the notes embedded below the screenshot, independent of marker size.
    /// Only the dev build lets you change it; releases always use standard.
    enum TextSize: String, CaseIterable {
        case standard, large, extraLarge

        static let defaultsKey = "annotationTextSize"
        static var current: Self {
            #if DEBUG
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .standard
            #else
            .standard
            #endif
        }

        var title: String {
            switch self {
            case .standard: "Standard"
            case .large: "Large"
            case .extraLarge: "Extra large"
            }
        }

        var points: CGFloat {
            switch self {
            case .standard: 15
            case .large: 22
            case .extraLarge: 30
            }
        }
    }

    /// Like a macOS window screenshot: each frame floats on transparent padding with a soft shadow.
    /// Frame labels sit on pills matching the Mac's light or dark mode, and notes on white, so they stay readable on any background.
    /// With no markers there's no card.
    static func png(for session: AnnotationSession) -> Data {
        // A screenshot is sent as just the marked part of the screen; its notes travel as text beside it.
        if session.recording == nil { return regionPNG(for: session) }
        let frames = sentFrames(of: session)
        let style = session.style
        let textSize = TextSize.current
        let textFactor = textSize.points / 15
        // Legend badges follow the note size, independently of the markers on the screenshot.
        let legendStyle = MarkerStyle(tint: style.tint)
        // Several frames are drawn at one pixel per point: the image is already large, and gets scaled down to be read.
        let scale = frames.count > 1 ? 1 : session.capture.pixelScale
        let crop = session.crop
        let sourceScale = session.source.pixelScale
        let tileWidth = (crop.width * scale).rounded()
        let tileHeight = (crop.height * scale).rounded()

        let margin = 48 * scale
        let gap = 28 * scale
        let cardGap = 20 * scale
        let padding = (16 + (textSize.points - 15) * 0.8) * scale
        let badgeScale = scale * textFactor
        let badgeSize = legendStyle.pinRadius * 2 * badgeScale
        let rowSpacing = 10 * badgeScale

        // As square as possible, so the frames stay large when the image is scaled to fit.
        let columns = (1...frames.count).min { a, b in
            squareness(columns: a, count: frames.count, tile: CGSize(width: tileWidth, height: tileHeight))
                < squareness(columns: b, count: frames.count, tile: CGSize(width: tileWidth, height: tileHeight))
        } ?? 1
        let rows = (frames.count + columns - 1) / columns

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let labels: [NSAttributedString] = frames.count <= 1 ? [] : frames.enumerated().map { index, frame in
            let seconds = frame.time.map { session.recording?.seconds($0) ?? 0 } ?? 0
            return NSAttributedString(string: "Frame \(index + 1) · \(String(format: "%.2f", seconds))s", attributes: [
                .font: NSFont.systemFont(ofSize: 14 * scale, weight: .semibold),
                .foregroundColor: NSColor(white: dark ? 0.92 : 0.15, alpha: 1),
            ])
        }
        let labelInset = CGSize(width: 8 * scale, height: 3 * scale)
        let pillHeight = labels.isEmpty ? 0 : height(of: labels[0], width: tileWidth) + labelInset.height * 2
        let labelHeight = labels.isEmpty ? 0 : pillHeight + 8 * scale
        let gridWidth = CGFloat(columns) * tileWidth + CGFloat(columns - 1) * gap
        let gridHeight = CGFloat(rows) * (labelHeight + tileHeight) + CGFloat(rows - 1) * gap

        var explanation = "\(style.tint.name) numbered pins and boxes are feedback markers, not part of the app."
        if frames.count > 1 {
            explanation = "Frames 1–\(frames.count) are stills from one screen recording, in time order. " + explanation
        }
        if let recording = session.recording, frames.contains(where: { $0.time.map { !recording.clicks(at: $0).isEmpty } ?? false }) {
            explanation += " White rings show mouse clicks: filled while the button is held down, hollow where it was let go, dashed for a right click."
        }
        let header = NSAttributedString(string: explanation, attributes: [
            .font: NSFont.systemFont(ofSize: (13 + (textSize.points - 15) / 2) * scale, weight: .medium),
            .foregroundColor: NSColor(white: 0.4, alpha: 1),
        ])
        let notes = frames.flatMap(\.markers).map { marker in
            let text = marker.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return NSAttributedString(string: text.isEmpty ? "(no note)" : text, attributes: [
                .font: NSFont.systemFont(ofSize: textSize.points * scale),
                .foregroundColor: NSColor(white: 0.1, alpha: 1),
            ])
        }

        let noteX = padding + badgeSize + 10 * badgeScale
        let headerHeight = height(of: header, width: gridWidth - padding * 2)
        let noteHeights = notes.map { max(height(of: $0, width: gridWidth - noteX - padding), badgeSize) }
        let cardHeight = (padding + headerHeight + 14 * badgeScale
            + noteHeights.reduce(0, +) + rowSpacing * CGFloat(max(notes.count - 1, 0)) + padding).rounded(.up)

        let pixelWidth = Int(gridWidth + margin * 2)
        let hasCard = !notes.isEmpty
        let pixelHeight = Int((margin + gridHeight + (hasCard ? cardGap + cardHeight : 0) + margin).rounded(.up))
        let total = CGFloat(pixelHeight)

        guard let cg = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        cg.interpolationQuality = CGInterpolationQuality.high

        /// Where each frame goes, top-left origin.
        let tiles = frames.indices.map { index in
            CGRect(
                x: margin + CGFloat(index % columns) * (tileWidth + gap),
                y: margin + CGFloat(index / columns) * (labelHeight + tileHeight + gap) + labelHeight,
                width: tileWidth, height: tileHeight
            )
        }
        let cardRect = CGRect(x: margin, y: margin + gridHeight + cardGap, width: gridWidth, height: cardHeight)

        // Frames and card with shadows, in Core Graphics' native bottom-left space.
        let flipped = { (rect: CGRect) in CGRect(x: rect.minX, y: total - rect.maxY, width: rect.width, height: rect.height) }
        let cropPixels = CGRect(x: crop.minX * sourceScale, y: crop.minY * sourceScale,
                                width: crop.width * sourceScale, height: crop.height * sourceScale).integral
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        for (frame, tile) in zip(frames, tiles) {
            cg.draw(frame.image.cropping(to: cropPixels) ?? frame.image, in: flipped(tile))
        }
        if hasCard {
            cg.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 16 * scale, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            cg.addPath(CGPath(roundedRect: flipped(cardRect), cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            cg.setFillColor(NSColor.white.cgColor)
            cg.fillPath()
        }
        cg.restoreGState()

        // Labels, markers and notes top-left-origin, like the overlay.
        cg.translateBy(x: 0, y: total)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        for (label, tile) in zip(labels, tiles) {
            let textWidth = label.boundingRect(with: CGSize(width: tileWidth, height: .greatestFiniteMagnitude), options: drawingOptions).width.rounded(.up)
            let pill = CGRect(x: tile.minX, y: tile.minY - labelHeight, width: textWidth + labelInset.width * 2, height: pillHeight)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 8 * scale, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            cg.addPath(CGPath(roundedRect: pill, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil))
            cg.setFillColor(NSColor(white: dark ? 0.18 : 1, alpha: 1).cgColor)
            cg.fillPath()
            cg.restoreGState()
            label.draw(with: pill.insetBy(dx: labelInset.width, dy: labelInset.height), options: drawingOptions)
        }
        NSGraphicsContext.restoreGraphicsState()

        var number = 1
        for (frame, tile) in zip(frames, tiles) {
            cg.saveGState()
            cg.clip(to: tile)
            cg.translateBy(x: tile.minX, y: tile.minY)
            style.paint(frame.markers, within: session.bounds, selectedID: nil, draft: nil, scale: scale, firstNumber: number, in: cg)
            cg.restoreGState()
            number += frame.markers.count
        }

        if hasCard {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            var y = cardRect.minY + padding
            header.draw(with: CGRect(x: cardRect.minX + padding, y: y, width: gridWidth - padding * 2, height: headerHeight), options: drawingOptions)
            y += headerHeight + 14 * badgeScale

            for (index, note) in notes.enumerated() {
                let lineHeight = (note.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { NSLayoutManager().defaultLineHeight(for: $0) } ?? badgeSize
                legendStyle.paintBadge(index + 1, at: CGPoint(x: cardRect.minX + padding + badgeSize / 2, y: y + max(lineHeight, badgeSize) / 2), scale: badgeScale, selected: false)
                let textY = y + max(0, (badgeSize - lineHeight) / 2)
                note.draw(with: CGRect(x: cardRect.minX + noteX, y: textY, width: gridWidth - noteX - padding, height: noteHeights[index]), options: drawingOptions)
                y += noteHeights[index] + rowSpacing
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let image = cg.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    /// The frames as sent: a pin with no note is dropped, as it's almost always a stray click, so the numbers in the
    /// image and the text only count marks that say something (or boxes, which mark a region even without a note).
    static func sentFrames(of session: AnnotationSession) -> [AnnotationSession.Frame] {
        session.framesToSend.map { frame in
            var frame = frame
            frame.markers.removeAll { marker in
                if case .pin = marker.shape { marker.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false }
            }
            return frame
        }
    }

    /// The notes as plain text, copied with the image. One note goes as typed; several are numbered to match the
    /// marks in the image, skipping marks without a note. Nil when there are no notes.
    static func text(for session: AnnotationSession) -> String? {
        let notes = sentFrames(of: session).flatMap(\.markers).enumerated().compactMap { index, marker -> (Int, String)? in
            let note = marker.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : (index + 1, note)
        }
        if notes.count <= 1 { return notes.first?.1 }
        return notes.map { "\($0.0). \($0.1)" }.joined(separator: "\n")
    }

    /// The screenshot cropped to its markers (the boxes, and any pins beside them) with a little room around them,
    /// markers drawn on top. With only pins, or no markers, the whole screen.
    private static func regionPNG(for session: AnnotationSession) -> Data {
        let frame = sentFrames(of: session)[0]
        let style = session.style
        let scale = session.capture.pixelScale
        let bounds = session.bounds
        let markers = frame.markers
        let hasBox = markers.contains { if case .box = $0.shape { true } else { false } }
        var region = bounds
        if hasBox {
            let extents = markers.map { marker -> CGRect in
                switch marker.shape {
                case .box(let rect): rect
                case .pin(let point):
                    CGRect(x: point.x - style.pinRadius, y: point.y - style.pinRadius, width: style.pinRadius * 2, height: style.pinRadius * 2)
                }
            }
            let padding: CGFloat = 12
            region = extents.dropFirst().reduce(extents[0]) { $0.union($1) }
                .insetBy(dx: -padding, dy: -padding).intersection(bounds).integral
        }
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale,
                            width: region.width * scale, height: region.height * scale).integral
        guard let cropped = frame.image.cropping(to: pixels),
              let cg = CGContext(
                  data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return Data() }
        let height = CGFloat(cropped.height)
        cg.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        // Markers top-left-origin, like the overlay, shifted so the region's corner is the image's.
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -pixels.minX, y: -pixels.minY)
        style.paint(markers, within: bounds, selectedID: nil, draft: nil, scale: scale, in: cg)
        guard let image = cg.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    /// How far a grid of `count` tiles is from square; 0 is square.
    private static func squareness(columns: Int, count: Int, tile: CGSize) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return abs(log((CGFloat(columns) * tile.width) / (CGFloat(rows) * tile.height)))
    }

    private static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: drawingOptions).height.rounded(.up)
    }
}
