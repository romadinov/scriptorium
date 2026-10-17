import ReaderCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Send to Tasker": captures the current page or highlight into Tasker's Inbox via tasker://add.
@MainActor
enum TaskerSender {
    /// Tasker is installed (iOS needs "tasker" in LSApplicationQueriesSchemes to ask).
    static var isAvailable: Bool {
        let probe = URL(string: "\(TaskerLink.scheme)://")!
        #if os(iOS)
        return UIApplication.shared.canOpenURL(probe)
        #else
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
        #endif
    }

    static func send(_ model: ReaderModel, highlight: Highlight? = nil) {
        guard let link = model.readingLink(highlight: highlight) else { return }
        let url = TaskerLink.add(title: link.title, url: link.url, note: link.text)
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
    /// Edit › Copy Link (⌃⌘C): link, title and text in one pasteboard write. Tasker's Clip hotkey sends ⌃⌘C
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
