import Foundation

/// tasker://add — captures a reading location into Tasker (the user's task app).
/// Each value is encoded on its own: the Scriptorium deep link inside it has its own ? and &.
public enum TaskerLink {
    public static let scheme = "tasker"

    /// `quick`: save straight to Tasker's Inbox and come back (x-success); otherwise open its Quick Entry pre-filled.
    public static func add(title: String, url: URL, note: String? = nil, quick: Bool = true) -> URL {
        var parts = [("title", title), ("url", url.absoluteString)]
        if let note, !note.isEmpty { parts.append(("note", note)) }
        if quick { parts += [("quick", "1"), ("x-success", DeepLink.scheme + "://")] }
        let query = parts.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(scheme)://add?\(query)")!
    }

    /// Strict query-value encoding: only unreserved characters stay literal.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

/// What a reading location is called when it leaves Scriptorium: "Book — p. 12" or "Book — Chapter title".
public enum ReadingLocationTitle {
    public static func make(book: String, page: Int, chapterTitle: String?) -> String {
        if let chapterTitle, !chapterTitle.isEmpty { return "\(book) — \(chapterTitle)" }
        return "\(book) — p. \(page + 1)"
    }
}
