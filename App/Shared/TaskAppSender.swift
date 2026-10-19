import ReaderCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Send to Uberdoer" (`TaskAppLink.appName`): captures the current page or highlight into the task app's Inbox.
@MainActor
enum TaskAppSender {
    /// The task app is installed (iOS needs its schemes in LSApplicationQueriesSchemes to ask).
    static var isAvailable: Bool { scheme != nil }

    /// The newest scheme the installed build of the app handles.
    private static var scheme: String? {
        TaskAppLink.schemes.first { canOpen(URL(string: "\($0)://")!) }
    }

    private static func canOpen(_ url: URL) -> Bool {
        #if os(iOS)
        return UIApplication.shared.canOpenURL(url)
        #else
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #endif
    }

    /// A task about to be sent, editable first (iPhone/iPad show it in a sheet).
    struct Draft: Identifiable {
        let id = UUID()
        var title: String
        var note: String
        let link: URL
    }

    static func draft(_ model: ReaderModel, highlight: Highlight? = nil) -> Draft? {
        model.readingLink(highlight: highlight).map { Draft(title: $0.title, note: $0.text, link: $0.url) }
    }

    static func send(_ draft: Draft) {
        let url = TaskAppLink.add(title: draft.title, url: draft.link, note: draft.note, scheme: scheme ?? TaskAppLink.scheme)
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    static func send(_ model: ReaderModel, highlight: Highlight? = nil) {
        guard let link = model.readingLink(highlight: highlight) else { return }
        let url = TaskAppLink.add(title: link.title, url: link.url, note: link.text, scheme: scheme ?? TaskAppLink.scheme)
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// A link inside the book (web, or to another place in it) → the task app, noting where it was found.
    static func sendLink(_ url: URL, title: String?, from model: ReaderModel) {
        guard let add = model.taskAppLink(for: url, title: title, scheme: scheme ?? TaskAppLink.scheme) else { return }
        #if os(iOS)
        UIApplication.shared.open(add)
        #else
        NSWorkspace.shared.open(add)
        #endif
    }

    #if os(macOS)
    /// Edit › Copy Link (⌃⌘C): link, title and text in one pasteboard write. the task app's Clip hotkey sends ⌃⌘C
    /// to Scriptorium and reads public.url, public.url-name and the plain text.
    static func copyLink(_ model: ReaderModel) {
        guard let link = model.readingLink() else { return }
        let item = NSPasteboardItem()
        item.setString(link.url.absoluteString, forType: .URL)
        item.setString(link.title, forType: NSPasteboard.PasteboardType("public.url-name"))
        item.setString(link.text.isEmpty ? link.url.absoluteString : link.text, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
    #endif
}
