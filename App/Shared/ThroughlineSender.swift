import ReaderCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Send to Throughline": captures the current page or highlight into Throughline's Inbox via throughline://add.
@MainActor
enum ThroughlineSender {
    /// Throughline is installed (iOS needs its schemes in LSApplicationQueriesSchemes to ask).
    static var isAvailable: Bool { scheme != nil }

    /// throughline://, or the legacy tasker:// for an older build of the app.
    private static var scheme: String? {
        [ThroughlineLink.scheme, ThroughlineLink.legacyScheme].first { canOpen(URL(string: "\($0)://")!) }
    }

    private static func canOpen(_ url: URL) -> Bool {
        #if os(iOS)
        return UIApplication.shared.canOpenURL(url)
        #else
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #endif
    }

    static func send(_ model: ReaderModel, highlight: Highlight? = nil) {
        guard let link = model.readingLink(highlight: highlight) else { return }
        let url = ThroughlineLink.add(title: link.title, url: link.url, note: link.text, scheme: scheme ?? ThroughlineLink.scheme)
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// A link inside the book (web, or to another place in it) → Throughline, noting where it was found.
    static func sendLink(_ url: URL, title: String?, from model: ReaderModel) {
        guard let add = model.throughlineLink(for: url, title: title, scheme: scheme ?? ThroughlineLink.scheme) else { return }
        #if os(iOS)
        UIApplication.shared.open(add)
        #else
        NSWorkspace.shared.open(add)
        #endif
    }

    #if os(macOS)
    /// Edit › Copy Link (⌃⌘C): link, title and text in one pasteboard write. Throughline's Clip hotkey sends ⌃⌘C
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
