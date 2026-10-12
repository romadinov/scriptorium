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
        SharedTextFile.waitUntilCurrent(file)
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var text = SharedTextFile.currentText(at: url)
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

/// "Improvement notes.md" in iCloud Drive › Scriptorium (TaskPaper): ideas and problems noted while
/// using the app, each with where it happened, the build and an optional screenshot. Append-only.
public struct ImprovementNotes: Sendable {
    public static let projectName = "Improvement notes"
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Screenshots go next to the file, in "Improvement notes/".
    public var attachmentsDirectory: URL {
        file.deletingLastPathComponent().appending(path: "Improvement notes")
    }

    /// Appends a note; returns the screenshot's file name if one was saved.
    @discardableResult
    public func add(_ text: String, context: String, file book: String? = nil, build: String, device: String,
                    screenshot: Data? = nil, date: Date = Date()) throws -> String? {
        var attachment: String?
        if let screenshot {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            // Local time, as people see it ("Screenshot 2026-10-11 211529.png").
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let name = "Screenshot \(formatter.string(from: date)).png"
            try screenshot.write(to: attachmentsDirectory.appending(path: name))
            attachment = name
        }

        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        let first = lines.first ?? ""
        var tags: [(String, String?)] = [("date", TaskPaper.date(date)), ("where", context)]
        if let book { tags.append(("file", book)) }
        tags += [("build", build), ("device", device)]
        if let attachment { tags.append(("screenshot", "Improvement notes/\(attachment)")) }
        var entry = TaskPaper.item(first, tags: tags)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { entry += "\n" + TaskPaper.note(rest) }

        var inner: Error?
        var coordinationError: NSError?
        SharedTextFile.waitUntilCurrent(file)
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var content = SharedTextFile.currentText(at: url)
                if content.isEmpty { content = TaskPaper.project(Self.projectName) + "\n" }
                if !content.hasSuffix("\n") { content += "\n" }
                content += entry + "\n"
                try Data(content.utf8).write(to: url, options: .atomic)
            } catch { inner = error }
        }
        if let error = coordinationError ?? inner { throw error }
        return attachment
    }
}

/// Text files edited both here and elsewhere (another device, or a Mac) through iCloud Drive. Appending
/// from a stale local copy would overwrite the other side's edits, so wait for the latest version first,
/// and fold any conflict versions iCloud kept back in (line by line; a line marked @done wins).
enum SharedTextFile {
    static func waitUntilCurrent(_ url: URL, timeout: TimeInterval = 8) {
        guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var copy = url
            copy.removeAllCachedResourceValues()
            let status = (try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// The file's text with unresolved conflict versions merged in (and resolved). Call inside a write coordination.
    static func currentText(at url: URL) -> String {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in conflicts {
            if let other = try? String(contentsOf: version.url, encoding: .utf8) { text = merge(text, other) }
            version.isResolved = true
        }
        if !conflicts.isEmpty { try? NSFileVersion.removeOtherVersionsOfItem(at: url) }
        return text
    }

    /// Lines of `b` missing from `a` are added after the line they followed in `b`; when the same item
    /// appears in both and only one copy carries @done(...) tags, that copy is kept.
    static func merge(_ a: String, _ b: String) -> String {
        func key(_ line: String) -> String {
            line.replacingOccurrences(of: #"\s@(done|fix)(\([^)]*\))?"#, with: "", options: .regularExpression)
        }
        var lines = a.components(separatedBy: "\n")
        var index = Dictionary(lines.enumerated().map { (key($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        var previous: Int?
        for line in b.components(separatedBy: "\n") {
            let k = key(line)
            if let i = index[k] {
                if line.contains("@done"), !lines[i].contains("@done") { lines[i] = line }
                previous = i
            } else if !line.isEmpty {
                let at = previous.map { $0 + 1 } ?? lines.count
                lines.insert(line, at: at)
                index = Dictionary(lines.enumerated().map { (key($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
                previous = at
            }
        }
        return lines.joined(separator: "\n")
    }
}
