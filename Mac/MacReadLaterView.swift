import ReaderCore
import SwiftUI

/// Links saved with "Add to Read Later" on any device (iCloud Drive › Scriptorium › Read Later.md).
struct MacReadLaterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var entries: [ReadLaterList.Entry] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List(entries.filter { !$0.done }, id: \.url) { entry in
                Button {
                    if let url = URL(string: entry.url) { openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).lineLimit(2)
                        Text(entry.url).font(.caption).foregroundStyle(.tint).lineLimit(1)
                        if let source = entry.source {
                            Text("From \(source) · \(entry.added.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url, forType: .string)
                    }
                }
            }
            .overlay {
                if loaded && entries.filter({ !$0.done }).isEmpty {
                    ContentUnavailableView("Nothing to Read Later", systemImage: "text.badge.plus",
                                           description: Text("Right-click a link in a book › Add Link to Read Later."))
                }
            }
            .navigationTitle("Read Later")
            .toolbar {
                ToolbarItem { Button("Show File in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([InboxLocation.readLaterFile()])
                } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            entries = await Task.detached { ReadLaterList(file: InboxLocation.readLaterFile()).entries() }.value
            loaded = true
        }
    }
}
