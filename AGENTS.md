# Agent Instructions

> **Fork note (Quick Capture)**: this is a fork of Show & Tell, published at KirschX/quick-capture. Releases are ad-hoc signed universal zips on GitHub Releases (asset `QuickCapture.zip`); there is no Developer ID, notarization or Sparkle feed, so the upstream release/push sections below don't apply. Debug builds install as `/Applications/Quick Capture Dev.app` (`com.kirschx.quickcapture.dev`). README.md (Korean) is the user and agent install guide.

Show & Tell is a menu bar app: press a shortcut, annotate the front window with numbered pins and boxes, copy it as one image and switch to Claude (or Codex) to paste it in (notes are drawn into it, not sent as text). Keep one implementation, no fallbacks unless asked, no tests unless asked.

## Builds

Test by hand; screen automation is unreliable with the overlay. Build, install and relaunch with `scripts/dev.sh`. It installs the Debug build as `/Applications/Show & Tell Dev.app` (bundle ID `com.oralart.showandtell.dev`, the user's day-to-day copy) and relaunches it. Writing to /Applications needs the sandbox off.

Keep Apple Development signing and the separate Debug bundle ID: Screen Recording and Accessibility grants are tied to the signature, so they survive rebuilds but break if a release and a dev build share an ID.

The Xcode project is generated from `project.yml` with XcodeGen; edit that and run `xcodegen generate`.

## Releasing

Commit each chunk of changes as soon as it builds, before starting the next request: one commit per change, so each subject reads as one release note.

When you finish working in a worktree branch, merge it into main yourself: fast-forward the main checkout at the repository root (`git merge --ff-only <branch>`), rebasing the branch onto main first if it has moved.

Push main with `scripts/push.sh`, not `git push`: it pushes, then releases the next patch version (1.0.6 → 1.0.7) through `release.sh` if there are `feat:`, `fix:` or `perf:` commits since the last release tag. It needs the sandbox off. Run `release.sh` by hand for a bigger version jump.

`scripts/release.sh <version>` archives, signs with Developer ID (Xcode's cloud-managed certificate), notarizes, makes the DMG, writes Sparkle's `appcast.xml` and publishes both to a GitHub Release. Commit first; the build number is the commit count. Release notes are the `feat:`, `fix:` and `perf:` commit subjects since the last release, so write those for users. Setup and details are in README.md.

## Demo

`demo/<name>` are templates for the README GIF. The working demo is a separate Git repo at `../snapback-demo`, served on port 8766; select that folder in Claude before recording. `scripts/record-demo.sh <name>` replays `demo/takes/<name>.json` through the real annotation session (Debug builds only), using the take's exact window size. Click the visible Copy & Open Claude button, paste with ⌘V, then verify the single attached image and submit with no text after a short pause. The page reloads after Claude edits it. Read `demo/HANDOFF.md` for practical lessons and `demo/README.md` for setup and the tracked GIF exporter.

## App icon

`ShowAndTell/AppIcon.icon` is an Icon Composer icon: the background colour is the `fill` in its `icon.json`, and the artwork layers are drawn by `Icon/render-icon.swift` (run command at the top of that file). Edit the script and re-run it rather than editing the PNGs. The Debug build uses `ShowAndTell/AppIconDev.icon`, the same artwork on orange; the script writes both.

## Architecture

- `App`: entry point and menu, shortcut, permissions window, `AppWindows` (open windows through it so they come to the front), and `CaptureCoordinator` (capture → overlay → save/copy).
- `Capture`: front window capture with ScreenCaptureKit, and `ScreenRecorder`, which records the front window's display to a temporary HEVC movie (pointer shown, Show & Tell's own windows such as the stop pill left out, 60s limit). Clicks are logged alongside it, not recorded; `Recording` draws them as white rings onto the frames decoded from it, filled while held and hollow once let go. To check their timing, record `scripts/click-calibration.html` in a browser; the steps are on the page.
- `Overlay`: `Marker` and `AnnotationSession` (frames, crop, selection, undo), `MarkerStyle` (marker drawing, shared with the image), the overlay view, note bubble, toolbar and panel. A screenshot is one frame; a recording (`Recording`: frame times and exact frame decoding) has up to six kept frames, picked on `RecordingTimeline`, with markers numbered across them.
- `Output`: `FeedbackImage` renders the PNG that's sent: shadowed window (or a recording's frames in a grid) with markers, notes in a card underneath.
- `Send`: copies the image to the clipboard, plays the sound chosen in Settings, shows `CopiedToast` (`UI`), and for Copy & Open brings Claude's or Codex's window (`SendTarget`, chosen in Settings) to the front as it is (no new chat) and focuses its message box through Accessibility; the user pastes it. The sounds are SND01 "sine" from snd.dev; keep the files unmodified (their terms).
- `Storage`: the last 20 sent or saved captures in `~/Library/Application Support/Show & Tell/Captures`, reopened from the menu's Recent submenu or the history window (`UI`). `capture.json` stores markers as `{kind, rect, note}`; keep that format readable. A recording keeps `recording.mov` instead of `window.png`, and its crop, frames (exact movie times) and clicks in `capture.json`.
