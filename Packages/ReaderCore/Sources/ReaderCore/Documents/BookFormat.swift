import Foundation

/// Recognises a book by its first bytes, for files that arrive without an extension.
public enum BookFormat {
    /// "pdf", "djvu", "epub", "azw3" or "fb2", or nil if the contents aren't a book Scriptorium reads.
    public static func sniffExtension(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024), !head.isEmpty else { return nil }
        let bytes = [UInt8](head)
        func starts(_ text: String, at offset: Int = 0) -> Bool {
            let magic = Array(text.utf8)
            return bytes.count >= offset + magic.count && Array(bytes[offset..<offset + magic.count]) == magic
        }
        if starts("%PDF-") { return "pdf" }
        if starts("AT&TFORM") { return "djvu" }
        // EPUB: a zip whose first entry is "mimetype" holding "application/epub+zip".
        if starts("PK\u{3}\u{4}"), starts("mimetype", at: 30), starts("application/epub+zip", at: 38) { return "epub" }
        if starts("BOOKMOBI", at: 60) { return "azw3" }
        if let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1),
           text.hasPrefix("<?xml") || text.hasPrefix("\u{FEFF}<?xml"), text.contains("<FictionBook") { return "fb2" }
        return nil
    }
}
