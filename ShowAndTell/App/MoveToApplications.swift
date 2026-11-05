import AppKit

/// Show & Tell can't update itself (or open at login reliably) when it's run straight from the disk image,
/// or from where macOS runs downloaded apps that weren't moved into place ("App Translocation").
/// Offers to copy itself into Applications and relaunch from there.
enum MoveToApplications {
    static func offerIfNeeded() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return }

        let alert = NSAlert()
        alert.messageText = "Move Show & Tell to Applications?"
        alert.informativeText = "It's running from the disk image, so it can't update itself."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(filePath: "/Applications/Show & Tell.app")
        do {
            if FileManager.default.fileExists(atPath: destination.path()) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: destination)
            // The person has already opened it once, so Gatekeeper has checked it; without the download flag
            // the copy isn't translocated again.
            let xattr = Process()
            xattr.executableURL = URL(filePath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", destination.path()]
            try xattr.run()
            xattr.waitUntilExit()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move Show & Tell"
            failure.informativeText = "Drag Show & Tell into your Applications folder, then open it from there."
            failure.runModal()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
