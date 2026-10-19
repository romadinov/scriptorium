// Records handled improvement notes. The iPad app is the only writer of "Improvement notes.md" (it appends
// new notes); this script is the only writer of "Improvement notes status.md". One writer per file, so
// iCloud never has two devices rewriting the same file.
//
// Usage: swift scripts/mark-improvement-done.swift ["<text in the note>" "<fix description>"]...
// Prints the notes that are still open. With no arguments it only rewrites the status file and lists.
import Foundation

let folder = URL(fileURLWithPath: NSString(string: "~/Library/Mobile Documents/iCloud~com~romadinov~reader/Documents").expandingTildeInPath)
let notesURL = folder.appending(path: "Improvement notes.md")
let statusURL = folder.appending(path: "Improvement notes status.md")
let ledgerURL = folder.appending(path: "Improvement notes/.handled.json")

struct Handled: Codable, Equatable { var note: String; var date: String; var done: String; var fix: String }

/// A note's first line without its tags; identifies it across edits.
func key(_ line: String) -> String {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("- ") { text.removeFirst(2) }
    if let tag = text.range(of: #"\s@[\w-]+(\(|\s|$)"#, options: .regularExpression) { text = String(text[..<tag.lowerBound]) }
    return text.trimmingCharacters(in: .whitespaces)
}

func tag(_ name: String, in line: String) -> String? {
    guard let r = line.range(of: "@\(name)\\(([^)]*)\\)", options: .regularExpression) else { return nil }
    return String(line[r].dropFirst(name.count + 2).dropLast())
}

// Read the ledger through file coordination (downloads it if iCloud evicted it). If it exists but can't be
// read, stop: starting from an empty ledger and saving it once wiped every handled note (2026-10-17).
var ledger: [String: Handled] = [:]
var ledgerData: Data?
var ledgerError: NSError?
if FileManager.default.fileExists(atPath: ledgerURL.path) || FileManager.default.isUbiquitousItem(at: ledgerURL) {
    try? FileManager.default.startDownloadingUbiquitousItem(at: ledgerURL)
    NSFileCoordinator().coordinate(readingItemAt: ledgerURL, options: [], error: &ledgerError) { ledgerData = try? Data(contentsOf: $0) }
    guard let ledgerData, let decoded = try? JSONDecoder().decode([String: Handled].self, from: ledgerData) else {
        print("Can't read \(ledgerURL.path) (\(ledgerError?.localizedDescription ?? "unreadable")); not changing anything.")
        exit(1)
    }
    ledger = decoded
}
let ledgerBefore = ledger
let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
let args = Array(CommandLine.arguments.dropFirst())
var pending: [(match: String, fix: String)] = stride(from: 0, to: args.count - 1, by: 2).map { (args[$0], args[$0 + 1]) }

// Read only — never write the notes file.
var notes: [String] = []
var error: NSError?
NSFileCoordinator().coordinate(readingItemAt: notesURL, options: [], error: &error) { url in
    notes = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("\t- ") }
}
if let error { print("read error: \(error)") }

for line in notes {
    let k = key(line)
    if let p = pending.firstIndex(where: { line.contains($0.match) }) {
        ledger[k] = Handled(note: k, date: tag("date", in: line) ?? "", done: today, fix: pending[p].fix)
        pending.remove(at: p)
    } else if ledger[k] == nil, line.contains("@done"), let fix = tag("fix", in: line) {
        // Marks made in the notes file before this scheme: carry them over.
        ledger[k] = Handled(note: k, date: tag("date", in: line) ?? "", done: tag("done", in: line) ?? today, fix: fix)
    }
}
for p in pending { print("no note matches: \(p.match)") }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try? FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
// Write only when something changed (listing alone never writes).
if ledger != ledgerBefore {
    let data = try encoder.encode(ledger)
    NSFileCoordinator().coordinate(writingItemAt: ledgerURL, options: .forReplacing, error: &error) { url in
        try? data.write(to: url, options: .atomic)
    }
}

// Status file (TaskPaper), newest first.
func clean(_ s: String) -> String { s.replacingOccurrences(of: ")", with: "]").replacingOccurrences(of: "(", with: "[") }
var status = ["Handled improvement notes:"]
for h in ledger.values.sorted(by: { ($0.done, $0.date) > ($1.done, $1.date) }) {
    status.append("\t- \(h.note) @noted(\(h.date)) @done(\(h.done)) @fix(\(clean(h.fix)))")
}
if ledger != ledgerBefore {
    NSFileCoordinator().coordinate(writingItemAt: statusURL, options: .forReplacing, error: &error) { url in
        try? (status.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

let open = notes.filter { ledger[key($0)] == nil }
print(open.isEmpty ? "No open notes." : "Open notes:\n" + open.joined(separator: "\n"))
