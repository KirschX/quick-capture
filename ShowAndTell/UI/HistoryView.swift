import SwiftUI

/// Recent captures. Clicking one reopens it in the overlay to change and copy again.
struct HistoryView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    private let store = CaptureStore.shared

    var body: some View {
        Group {
            if store.captures.isEmpty {
                ContentUnavailableView("No captures yet", systemImage: "camera.viewfinder")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 20) {
                        ForEach(store.captures) { saved in
                            Button {
                                dismissWindow(id: "history")
                                CaptureCoordinator.shared.reopen(saved)
                            } label: {
                                CaptureCard(saved: saved, thumbnail: store.thumbnails[saved.id])
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([store.folder(of: saved.id)])
                                }
                                Button("Delete", role: .destructive) {
                                    store.delete(saved.id)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

private struct CaptureCard: View {
    let saved: SavedCapture
    let thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            Text(saved.windowTitle ?? saved.appName)
                .font(.headline)
                .lineLimit(1)
            Text("\(saved.recording == nil ? "" : "Recording · ")\(saved.appName) · \(saved.displayDate)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
