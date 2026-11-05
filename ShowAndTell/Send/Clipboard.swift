import AppKit

enum Clipboard {
    /// Kept while the image is on the clipboard; they make the TIFF and the text only when an app pastes them.
    private static var tiffProvider: TIFFProvider?
    private static var textProvider: TextProvider?

    /// Puts the annotated image on the clipboard as PNG (plus TIFF for apps that only paste that) and the notes as
    /// plain text in the same item, so one ⌘V in Claude (desktop or web) attaches the image and types the notes.
    /// A terminal only takes the text, so when one pastes, the text ends with the image saved as a file instead,
    /// which Claude Code reads from the path.
    static func copy(png: Data, text: String?) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let tiff = TIFFProvider(png: png)
        item.setDataProvider(tiff, forTypes: [.tiff])
        tiffProvider = tiff
        let textProvider = TextProvider(text: text, imagePath: CaptureFiles.save(png))
        item.setDataProvider(textProvider, forTypes: [.string])
        self.textProvider = textProvider

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: type)
        }
    }
}

/// The notes, decided when an app pastes: the app pasting is the one in front. Terminals and editors (where Claude
/// Code runs) also get the image's file path; apps that take the image itself get just the notes.
private final class TextProvider: NSObject, NSPasteboardItemDataProvider {
    static let textOnlyApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper", "com.stablyai.orca",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    let text: String?
    let imagePath: String?

    init(text: String?, imagePath: String?) {
        self.text = text
        self.imagePath = imagePath
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let pasting = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        var parts = [text].compactMap { $0 }
        if Self.textOnlyApps.contains(pasting), let imagePath { parts.append(imagePath) }
        item.setString(parts.joined(separator: "\n\n"), forType: type)
    }
}

/// Copied images as files, for pasting into a terminal by path. Only the newest few are kept.
private enum CaptureFiles {
    static let kept = 30

    static var directory: URL {
        let id = Bundle.main.bundleIdentifier ?? "quickcapture"
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/\(id)/clipboard", directoryHint: .isDirectory)
    }

    /// Saves the image and returns its path (with no spaces, so it pastes as one word), or nil if it couldn't be written.
    static func save(_ png: Data) -> String? {
        let manager = FileManager.default
        let directory = directory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = directory.appending(path: "capture-\(formatter.string(from: .now)).png")
            try png.write(to: url)
            prune(directory)
            return url.path
        } catch {
            return nil
        }
    }

    private static func prune(_ directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        // Names sort by time.
        for old in files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(kept) {
            try? manager.removeItem(at: old)
        }
    }
}
