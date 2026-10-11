import Foundation

/// Minimal TaskPaper formatting: `Project:` lines, tab-indented `- item @tag(value)` lines, notes as
/// further-indented plain lines. Plain text that reads fine as Markdown too.
public enum TaskPaper {
    public static func project(_ name: String) -> String {
        oneLine(name).replacingOccurrences(of: ":", with: " –") + ":"
    }

    /// `- text @tag(value) @tag2` (value nil → bare tag). Text is folded onto one line.
    public static func item(_ text: String, tags: [(String, String?)], indent: Int = 1) -> String {
        let tabs = String(repeating: "\t", count: indent)
        let tagText = tags.map { name, value in
            value.map { "@\(name)(\(tagValue($0)))" } ?? "@\(name)"
        }.joined(separator: " ")
        return tabs + "- " + oneLine(text) + (tagText.isEmpty ? "" : " " + tagText)
    }

    public static func note(_ text: String, indent: Int = 2) -> String {
        let tabs = String(repeating: "\t", count: indent)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { tabs + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Tag values can't contain parentheses or line breaks.
    static func tagValue(_ value: String) -> String {
        oneLine(value).replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
    }

    public static func date(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// Items (`- …`) under `project`, with their tags — used to show the list in the app.
    public static func items(in text: String, project name: String) -> [(text: String, tags: [String: String])] {
        var inProject = false
        var result: [(String, [String: String])] = []
        let tag = try! NSRegularExpression(pattern: "\\s@([\\w-]+)(?:\\(([^)]*)\\))?")
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), line.hasSuffix(":") {
                inProject = line.dropLast() == Substring(project(name).dropLast())
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard inProject, trimmed.hasPrefix("- ") else { continue }
            let body = String(trimmed.dropFirst(2))
            let ns = body as NSString
            var tags: [String: String] = [:]
            var firstTag = ns.length
            for m in tag.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                firstTag = min(firstTag, m.range.location)
                let value = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                tags[ns.substring(with: m.range(at: 1))] = value
            }
            result.append((ns.substring(to: firstTag).trimmingCharacters(in: .whitespaces), tags))
        }
        return result
    }
}

/// "Read Later.md" in iCloud Drive › Scriptorium (TaskPaper format). The app only appends, so anything
/// edited elsewhere (TaskPaper marking items @done, reordering, deleting) is preserved.
public struct ReadLaterList: Sendable {
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var url: String
        public var source: String?
        public var added: Date
        public var done: Bool

        public init(title: String, url: String, source: String? = nil, added: Date = Date(), done: Bool = false) {
            self.title = title
            self.url = url
            self.source = source
            self.added = added
            self.done = done
        }
    }

    public static let projectName = "Read Later"
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Adds an entry unless the same URL is already listed (and not done).
    @discardableResult
    public func add(_ entry: Entry) throws -> Bool {
        var added = false
        var inner: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if TaskPaper.items(in: text, project: Self.projectName)
                    .contains(where: { $0.tags["url"] == TaskPaper.tagValue(entry.url) && $0.tags["done"] == nil }) {
                    return
                }
                var tags: [(String, String?)] = [("url", entry.url)]
                if let source = entry.source { tags.append(("from", source)) }
                tags.append(("added", TaskPaper.date(entry.added)))
                let line = TaskPaper.item(entry.title, tags: tags)
                let header = TaskPaper.project(Self.projectName)
                if let range = text.range(of: "(?m)^" + NSRegularExpression.escapedPattern(for: header) + "$",
                                          options: .regularExpression) {
                    // Append at the end of the project's block (before the next top-level line).
                    let after = text[range.upperBound...]
                    let nextProject = after.range(of: "\n(?=[^\t\n ])", options: .regularExpression)
                    let insertAt = nextProject?.lowerBound ?? text.endIndex
                    let needsNewline = !(text[..<insertAt].hasSuffix("\n"))
                    text.insert(contentsOf: (needsNewline ? "\n" : "") + line + (nextProject == nil ? "\n" : ""), at: insertAt)
                } else {
                    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                    if !text.isEmpty { text += "\n" }
                    text += header + "\n" + line + "\n"
                }
                try Data(text.utf8).write(to: url, options: .atomic)
                added = true
            } catch { inner = error }
        }
        if let error = coordinationError ?? inner { throw error }
        return added
    }

    public func entries() -> [Entry] {
        var result: [Entry] = []
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            result = TaskPaper.items(in: text, project: Self.projectName).map { item in
                Entry(title: item.text, url: item.tags["url"] ?? "", source: item.tags["from"],
                      added: (item.tags["added"]).flatMap { try? Date($0, strategy: .iso8601.year().month().day()) } ?? Date(),
                      done: item.tags["done"] != nil)
            }
        }
        return result
    }
}
