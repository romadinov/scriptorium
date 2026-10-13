import ReaderCore
import SwiftUI

/// Scriptorium for the Mac: a library window and one window per open book. The library is local to
/// this Mac; highlights, bookmarks, notes, Read Later and reading positions sync with the iPad through iCloud.
@main
struct ScriptoriumMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var library = LibraryStore()
    @State private var settings = SettingsStore()
    @State private var router = MacRouter.shared

    var body: some Scene {
        Window("Library", id: "library") {
            MacLibraryView()
                .environment(library)
                .environment(settings)
                .environment(router)
                .environment(DeviceTransfers.shared)
                .task {
                    DeviceTransfers.shared.onImported = { [library] in library.reload() }
                    await DeviceTransfers.shared.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await DeviceTransfers.shared.start() }
                }
        }
        .defaultSize(width: 1000, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Books…") { router.importRequested = true }
                    .keyboardShortcut("o")
                Button("New Folder") { router.newFolderRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
            }
            ReaderCommands()
        }

        WindowGroup("Book", id: "book", for: URL.self) { $url in
            if let url {
                MacReaderView(book: Book(url: url))
                    .environment(library)
                    .environment(settings)
                    .environment(router)
                    .environment(DeviceTransfers.shared)
            }
        }
        .defaultSize(width: 1120, height: 820)

        Window("Send Book", id: "send-book") {
            SendBookView()
                .environment(DeviceTransfers.shared)
                .frame(width: 420, height: 480)
        }
        .windowResizability(.contentSize)

        Settings {
            MacSettingsView()
                .environment(settings)
        }
    }
}

/// Files and links that arrive from outside (Finder "Open With", scriptorium:// links) are queued here
/// and handled by the library window, which can import them and open reader windows.
@MainActor @Observable
final class MacRouter {
    static let shared = MacRouter()
    var incoming: [URL] = []
    var importRequested = false
    var newFolderRequested = false
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { CrashReporter.shared.start() }   // → iCloud Drive › Scriptorium › Crash reports
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { MacRouter.shared.incoming += urls }
    }

    /// Closing the last book window keeps the app (and the library window) around, like Books.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Reader menu commands

/// The focused book window's model, for menu commands.
struct ReaderFocusKey: FocusedValueKey { typealias Value = MacReaderActions }

extension FocusedValues {
    var reader: MacReaderActions? {
        get { self[ReaderFocusKey.self] }
        set { self[ReaderFocusKey.self] = newValue }
    }
}

/// What the menus can do in the focused book window.
struct MacReaderActions {
    let model: ReaderModel
    let toggleAssistant: () -> Void
    let toggleSidebar: () -> Void
    let goToPage: () -> Void
}

struct ReaderCommands: Commands {
    @FocusedValue(\.reader) private var reader
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Go") {
            Group {
            Button("Previous Page") { reader?.model.pageBackward() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Page") { reader?.model.pageForward() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Go to Page…") { reader?.goToPage() }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
            Button("Back") { reader?.model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(reader?.model.backStack.isEmpty ?? true)
            }
            .disabled(reader == nil)
        }
        CommandMenu("Book") {
            Group {
            Button(reader?.model.currentBookmark == nil ? "Add Bookmark" : "Remove Bookmark") {
                guard let model = reader?.model else { return }
                Task { await model.toggleBookmark() }
            }
            .keyboardShortcut("d")
            Button("Page Note…") {
                guard let model = reader?.model else { return }
                Task { await model.annotatePage() }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Highlight Selection") {
                guard let model = reader?.model else { return }
                Task { await model.addHighlight() }
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(reader?.model.selection.isEmpty ?? true)
            Button("Note on Selection…") {
                guard let model = reader?.model else { return }
                Task { await model.annotateSelection() }
            }
            .disabled(reader?.model.selection.isEmpty ?? true)
            Divider()
            Button(reader?.model.readAloud.state == .idle ? "Read Aloud" : "Stop Reading Aloud") {
                guard let model = reader?.model else { return }
                if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Menu("Send To") {
                ForEach(DeviceTransfers.shared.devices) { device in
                    Button(device.name) {
                        guard let book = reader?.model.book.url else { return }
                        let parent = book.deletingLastPathComponent().standardizedFileURL
                        let root = LibraryStore.rootURL.standardizedFileURL
                        let folder = parent == root ? "" : String(parent.path.dropFirst(root.path.count + 1))
                        Task {
                            await DeviceTransfers.shared.prepareSend(book, folder: folder, to: device)
                            openWindow(id: "send-book")
                        }
                    }
                }
            }
            Button("Send to Kindle") {
                guard let book = reader?.model.book.url else { return }
                KindleSender.sendOnMac(book) { DeviceTransfers.shared.status = $0 }
            }
            .disabled(!(reader.map { KindleSender.supports($0.model.book.url) } ?? false))
            Divider()
            Button("Show Assistant") { reader?.toggleAssistant() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Show Contents & Bookmarks") { reader?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            .disabled(reader == nil)
        }
    }
}

extension ReaderModel {
    /// One screen/page back or forward, whatever the layout.
    func pageForward() { step(1) }
    func pageBackward() { step(-1) }

    private func step(_ delta: Int) {
        if let turnPage {
            turnPage(delta)
        } else {
            let target = currentPage + delta
            guard target >= 0, target < source.pageCount else { return }
            go(to: target, remember: false)
        }
    }
}
