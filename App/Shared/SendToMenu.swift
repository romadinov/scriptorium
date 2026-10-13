import ReaderCore
import SwiftUI

/// "Send to ›" a menu of the reader's other devices; the book goes to the same folder there.
struct SendToMenu: View {
    let book: URL
    @Environment(DeviceTransfers.self) private var transfers
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Menu("Send to", systemImage: "paperplane") {
            if transfers.devices.isEmpty {
                Text("Open Scriptorium on your other devices (signed in to the same iCloud) to see them here.")
            }
            ForEach(transfers.devices) { device in
                Button(device.name, systemImage: device.systemImage) {
                    let parent = book.deletingLastPathComponent().standardizedFileURL
                    let folder = parent == library.root.standardizedFileURL ? "" : library.relativePath(parent)
                    transfers.send(book, folder: folder, to: device)
                }
            }
        }
    }
}
