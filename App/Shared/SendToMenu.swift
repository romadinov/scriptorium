import ReaderCore
import SwiftUI

/// "Send to ›" a menu of the reader's other devices; choosing one asks which folder it goes to there.
struct SendToMenu: View {
    let book: URL
    @Environment(DeviceTransfers.self) private var transfers
    @Environment(LibraryStore.self) private var library
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Menu("Send to", systemImage: "paperplane") {
            if transfers.devices.isEmpty {
                Text("Open Scriptorium on your other devices (signed in to the same iCloud) to see them here.")
            }
            ForEach(transfers.devices) { device in
                Button(device.name, systemImage: device.systemImage) {
                    let parent = book.deletingLastPathComponent().standardizedFileURL
                    let folder = parent == library.root.standardizedFileURL ? "" : library.relativePath(parent)
                    transfers.pending = .init(book: book, device: device, folder: folder)
                    #if os(macOS)
                    openWindow(id: "send-book")
                    #endif
                }
            }
        }
    }
}

/// Where on the other device: its library folders (as it last reported them), or a new one.
struct SendBookView: View {
    @Environment(DeviceTransfers.self) private var transfers
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String = ""
    @State private var newFolder = ""
    @State private var creating = false

    var body: some View {
        if let pending = transfers.pending {
            content(pending)
                .onAppear {
                    selection = (pending.device.folders ?? []).contains(pending.folder) ? pending.folder : ""
                }
        } else {
            ContentUnavailableView("Nothing to Send", systemImage: "paperplane")
        }
    }

    private func content(_ pending: DeviceTransfers.PendingSend) -> some View {
        let folders = pending.device.folders ?? []
        return NavigationStack {
            List(selection: Binding(get: { creating ? nil : selection }, set: { if let value = $0 { selection = value; creating = false } })) {
                Section {
                    Label("Library", systemImage: "books.vertical").tag("")
                    ForEach(folders, id: \.self) { folder in
                        Label((folder as NSString).lastPathComponent, systemImage: "folder")
                            .padding(.leading, CGFloat(folder.split(separator: "/").count - 1) * 18)
                            .tag(folder)
                    }
                } header: {
                    Text("Folder on \(pending.device.name)")
                } footer: {
                    if pending.device.folders == nil {
                        Text("\(pending.device.name) hasn't shared its folders yet — open Scriptorium there once to see them.")
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.tint)
                        TextField("New folder", text: $newFolder)
                            .onChange(of: newFolder) { _, name in creating = !name.trimmingCharacters(in: .whitespaces).isEmpty }
                            .onSubmit { send(pending) }
                    }
                } footer: {
                    Text(creating ? "“\(destination(pending))” will be created on \(pending.device.name)."
                                  : "Or type a name to create a folder there (inside the selected one).")
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Send “\(pending.book.deletingPathExtension().lastPathComponent)”")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { transfers.pending = nil; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(pending) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The chosen folder, or a new folder inside it.
    private func destination(_ pending: DeviceTransfers.PendingSend) -> String {
        let name = newFolder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard creating, !name.isEmpty else { return selection }
        return selection.isEmpty ? name : selection + "/" + name
    }

    private func send(_ pending: DeviceTransfers.PendingSend) {
        transfers.send(pending.book, folder: destination(pending), to: pending.device)
        transfers.pending = nil
        dismiss()
    }
}
