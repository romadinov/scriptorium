// Lists crash reports not yet handled, symbolicated, from:
//   • iCloud Drive › Scriptorium › Crash reports — MetricKit reports saved by the apps (iPad, iPhone, Mac)
//   • the iPad's system crash logs (copied over when it's connected by cable)
// Usage: swift scripts/crash-reports.swift            — list new reports
//        swift scripts/crash-reports.swift --mark <file name>… — mark reports handled
// Symbols: ~/Library/Developer/Scriptorium/dSYMs/<build>/ (saved by scripts/install-release.sh).
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let workDir = home.appending(path: "Library/Developer/Scriptorium")
let ledgerURL = workDir.appending(path: "handled-crashes.json")
let ipsDir = workDir.appending(path: "DeviceCrashLogs")
let icloud = ProcessInfo.processInfo.environment["CRASH_REPORTS_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appending(path: "Library/Mobile Documents/iCloud~com~romadinov~reader/Documents/Crash reports")
let ipad = "00008103-0014312411E8A01E"
try? FileManager.default.createDirectory(at: ipsDir, withIntermediateDirectories: true)

@discardableResult
func run(_ tool: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

var ledger = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))) ?? [])
func saveLedger() { try? JSONEncoder().encode(ledger.sorted()).write(to: ledgerURL) }

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--mark" {
    for name in args.dropFirst() { ledger.insert(name) }
    saveLedger()
    print("Marked \(args.count - 1) report(s) handled.")
    exit(0)
}

// 1. The iPad's own crash logs, when connected.
if run("/usr/bin/xcrun", ["devicectl", "list", "devices"]).contains(ipad) {
    let listing = run("/usr/bin/xcrun", ["devicectl", "device", "info", "files", "--device", ipad, "--domain-type", "systemCrashLogs"])
    for line in listing.split(separator: "\n") {
        let name = line.split(separator: " ").first.map(String.init) ?? ""
        // App crashes, plus memory kills (JetsamEvent logs list every process iOS ended; kept if Scriptorium is one).
        guard name.hasPrefix("Reader") || name.hasPrefix("Scriptorium") || name.hasPrefix("JetsamEvent"), name.hasSuffix(".ips") else { continue }
        let dest = ipsDir.appending(path: name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            run("/usr/bin/xcrun", ["devicectl", "device", "copy", "from", "--device", ipad, "--domain-type", "systemCrashLogs",
                                   "--source", name, "--destination", dest.path])
        }
    }
}

// 2. Symbols by binary UUID.
var dsyms: [String: String] = [:]
let symRoot = workDir.appending(path: "dSYMs")
if let walker = FileManager.default.enumerator(at: symRoot, includingPropertiesForKeys: nil) {
    for case let url as URL in walker where url.path.contains(".dSYM/Contents/Resources/DWARF/") && !url.hasDirectoryPath {
        for line in run("/usr/bin/dwarfdump", ["--uuid", url.path]).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count > 1, parts[0] == "UUID:" { dsyms[String(parts[1]).uppercased()] = url.path }
        }
    }
}

func symbolicate(uuid: String, offset: UInt64) -> String? {
    guard let binary = dsyms[uuid.uppercased().replacingOccurrences(of: "-", with: "")] ?? dsyms[uuid.uppercased()] else { return nil }
    let base: UInt64 = 0x1_0000_0000
    let out = run("/usr/bin/atos", ["-o", binary, "-arch", "arm64", "-l", String(format: "0x%llx", base), String(format: "0x%llx", base + offset)])
    let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

// Normalise UUID keys (dwarfdump prints with dashes).
dsyms = Dictionary(dsyms.map { ($0.key.replacingOccurrences(of: "-", with: ""), $0.value) }, uniquingKeysWith: { a, _ in a })

var found = 0

// 3. MetricKit reports.
let reports = ((try? FileManager.default.contentsOfDirectory(at: icloud, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for url in reports where !ledger.contains(url.lastPathComponent) {
    guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { continue }
    found += 1
    print("\n=== \(url.lastPathComponent)")
    for key in ["crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics", "diskWriteExceptionDiagnostics"] {
        for diagnostic in json[key] as? [[String: Any]] ?? [] {
            let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
            print("\(key): exception=\(meta["exceptionType"] ?? "-") signal=\(meta["signal"] ?? "-") code=\(meta["exceptionCode"] ?? "-") os=\(meta["osVersion"] ?? "-") build=\(meta["appBuildVersion"] ?? "-")")
            if let reason = meta["terminationReason"] { print("  termination: \(reason)") }
            if let duration = meta["hangDuration"] { print("  hang: \(duration)") }
            let stacks = (diagnostic["callStackTree"] as? [String: Any])?["callStacks"] as? [[String: Any]] ?? []
            let thread = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
            var frame = (thread?["callStackRootFrames"] as? [[String: Any]])?.first
            var depth = 0
            while let f = frame, depth < 25 {
                let name = f["binaryName"] as? String ?? "?"
                let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
                let symbol = (f["binaryUUID"] as? String).flatMap { symbolicate(uuid: $0, offset: offset) }
                print(String(format: "  %2d  %@  %@", depth, name, symbol ?? String(format: "+0x%llx", offset)))
                frame = (f["subFrames"] as? [[String: Any]])?.first
                depth += 1
            }
        }
    }
}

// 4. iPad system crash logs (.ips: a JSON header line, then the JSON report).
let ipsFiles = ((try? FileManager.default.contentsOfDirectory(at: ipsDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "ips" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for url in ipsFiles where !ledger.contains(url.lastPathComponent) {
    if url.lastPathComponent.hasPrefix("JetsamEvent") {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let newline = text.firstIndex(of: "\n"),
              let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8))) as? [String: Any],
              let processes = body["processes"] as? [[String: Any]],
              let mine = processes.first(where: { ($0["name"] as? String) == "Reader" && $0["reason"] != nil }) else { continue }
        found += 1
        print("\n=== \(url.lastPathComponent) (iPad memory kill)")
        let pages = (mine["rpages"] as? NSNumber)?.intValue ?? 0
        print("Scriptorium was ended by iOS: reason=\(mine["reason"] ?? "-"), memory ≈ \(pages * 16 / 1024) MB, largest process: \(body["largestProcess"] ?? "-")")
        continue
    }
    guard let text = try? String(contentsOf: url, encoding: .utf8), let newline = text.firstIndex(of: "\n"),
          let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8))) as? [String: Any]
    else { continue }
    found += 1
    print("\n=== \(url.lastPathComponent) (iPad system log)")
    let exception = body["exception"] as? [String: Any] ?? [:]
    print("exception=\(exception["type"] ?? "-") signal=\(exception["signal"] ?? "-") build=\((body["bundleInfo"] as? [String: Any])?["CFBundleVersion"] ?? "-")")
    if let termination = body["termination"] as? [String: Any] { print("  termination: \(termination["indicator"] ?? termination)") }
    let images = body["usedImages"] as? [[String: Any]] ?? []
    let threads = body["threads"] as? [[String: Any]] ?? []
    let faulting = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil } ?? threads.first
    for (i, f) in ((faulting?["frames"] as? [[String: Any]]) ?? []).prefix(25).enumerated() {
        let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
        let offset = (f["imageOffset"] as? NSNumber)?.uint64Value ?? 0
        let name = image?["name"] as? String ?? "?"
        let symbol = (f["symbol"] as? String) ?? (image?["uuid"] as? String).flatMap { symbolicate(uuid: $0, offset: offset) }
        print(String(format: "  %2d  %@  %@", i, name, symbol ?? String(format: "+0x%llx", offset)))
    }
}

print(found == 0 ? "No new crash reports." : "\n\(found) new report(s). Mark handled: swift scripts/crash-reports.swift --mark \"<file name>\"")
