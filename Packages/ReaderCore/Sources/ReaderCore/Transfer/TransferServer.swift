import Foundation
import Network

/// "Wi-Fi Transfer": a small HTTP/1.1 server that lets a browser on the same network
/// browse the library folders, upload books, create folders, download and delete.
///
/// Deliberately minimal: one request per connection (`Connection: close`), no chunked
/// request bodies (browsers send `Content-Length` for `fetch`/XHR uploads), no auth —
/// it is meant to be switched on briefly while transferring files on a trusted network.
public final class TransferServer: @unchecked Sendable {
    public enum Event: Sendable {
        case changed            // library contents changed (upload, mkdir, delete, move)
        case stopped(Error?)
    }

    public let root: URL
    public var onEvent: (@Sendable (Event) -> Void)?
    public private(set) var port: UInt16?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Reader.TransferServer")

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Starts listening; resolves once the port is bound. Tries `preferredPort`, then any free port.
    public func start(preferredPort: UInt16 = 8080, bonjourName: String? = nil) async throws -> UInt16 {
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: preferredPort)!, bonjourName: bonjourName)
        } catch {
            return try await listen(on: .any, bonjourName: bonjourName)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func listen(on port: NWEndpoint.Port, bonjourName: String?) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        if let bonjourName { listener.service = NWListener.Service(name: bonjourName, type: "_http._tcp") }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            HTTPConnection(connection: connection, server: self).start(on: self.queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            // State updates arrive serially on `queue`; the box just carries the flag across them.
            let started = StartFlag()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard !started.value, let bound = listener?.port?.rawValue else { return }
                    started.value = true
                    self?.port = bound
                    continuation.resume(returning: bound)
                case .failed(let error):
                    listener?.cancel()
                    if !started.value {
                        started.value = true
                        continuation.resume(throwing: error)
                    } else {
                        self?.onEvent?(.stopped(error))
                    }
                case .cancelled:
                    if started.value { self?.onEvent?(.stopped(nil)) }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    // MARK: File operations (paths are relative to `root`)

    struct Entry: Encodable, Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int
        let modified: Double
    }

    enum Failure: Error {
        case badRequest(String), notFound, conflict(String), unsupported(String)
    }

    /// Resolves a client-supplied relative path, refusing anything that escapes `root`.
    func resolve(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains("..") else { throw Failure.badRequest("Invalid path") }
        let url = parts.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw Failure.badRequest("Invalid path") }
        return url
    }

    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != "..", !trimmed.hasPrefix(".") else {
            throw Failure.badRequest("Invalid name")
        }
        return trimmed
    }

    func list(_ relative: String) throws -> [Entry] {
        let dir = try resolve(relative)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                      options: .skipsHiddenFiles) else { throw Failure.notFound }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            guard isDir || DocumentOpener.canOpen(url) else { return nil }
            return Entry(name: url.lastPathComponent, isDirectory: isDir, size: values?.fileSize ?? 0,
                         modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    func makeDirectory(in relative: String, name: String) throws {
        let target = try resolve(relative).appending(path: try Self.validName(name))
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.conflict("Already exists") }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    }

    func delete(_ relative: String) throws {
        let target = try resolve(relative)
        guard target != root else { throw Failure.badRequest("Cannot delete the library") }
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.notFound }
        try FileManager.default.removeItem(at: target)
    }

    func move(_ from: String, toFolder: String) throws {
        let source = try resolve(from)
        let folder = try resolve(toFolder)
        guard source != root, !folder.path.hasPrefix(source.path + "/"), folder != source else {
            throw Failure.badRequest("Cannot move a folder into itself")
        }
        let target = LibraryFiles.uniqueURL(for: source.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: source, to: target)
    }

    /// Moves an uploaded temp file into place, renaming on collision ("Book 2.epub").
    func acceptUpload(_ temp: URL, folder relative: String, name: String) throws -> String {
        let name = try Self.validName(name)
        guard DocumentOpener.canOpen(URL(fileURLWithPath: name)) else {
            throw Failure.unsupported("Only PDF, DjVu, EPUB and FB2 files can be uploaded")
        }
        let folder = try resolve(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.notFound
        }
        let target = LibraryFiles.uniqueURL(for: name, in: folder)
        try FileManager.default.moveItem(at: temp, to: target)
        return target.lastPathComponent
    }

    func notifyChanged() { onEvent?(.changed) }
}

private final class StartFlag: @unchecked Sendable {
    var value = false
}

public enum LibraryFiles {
    /// `name` in `folder`, or "name 2.ext", "name 3.ext"… if taken. Handles double extensions like ".fb2.zip".
    public static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let lower = name.lowercased()
        let ext = lower.hasSuffix(".fb2.zip") ? "fb2.zip" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        repeat {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - One HTTP exchange

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: TransferServer
    private var buffer = Data()
    private static let maxHeader = 64 * 1024

    init(connection: NWConnection, server: TransferServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        readHead()
    }

    // MARK: Request parsing

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }
    }

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer[end.upperBound...]
                buffer = Data()
                guard let request = Self.parse(head) else { return send(400, text: "Bad request") }
                handle(request, initialBody: Data(rest))
            } else if error != nil || isComplete || buffer.count > Self.maxHeader {
                connection.cancel()
            } else {
                readHead()
            }
        }
    }

    private static func parse(_ head: String) -> Request? {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: components.path, query: query, headers: headers)
    }

    // MARK: Routing

    private func handle(_ request: Request, initialBody: Data) {
        do {
            switch (request.method, request.path) {
            case ("GET", "/"), ("GET", "/index.html"):
                send(200, body: Data(TransferPage.html.utf8), type: "text/html; charset=utf-8")
            case ("GET", "/api/list"):
                let entries = try server.list(request.query["path"] ?? "")
                send(200, json: ["path": request.query["path"] ?? "", "entries": entries])
            case ("POST", "/api/mkdir"):
                try server.makeDirectory(in: request.query["path"] ?? "", name: request.query["name"] ?? "")
                server.notifyChanged()
                send(200, json: ["ok": true])
            case ("POST", "/api/delete"):
                try server.delete(request.query["path"] ?? "")
                server.notifyChanged()
                send(200, json: ["ok": true])
            case ("POST", "/api/move"):
                try server.move(request.query["from"] ?? "", toFolder: request.query["to"] ?? "")
                server.notifyChanged()
                send(200, json: ["ok": true])
            case ("PUT", "/api/upload"), ("POST", "/api/upload"):
                guard request.headers["transfer-encoding"] == nil else {
                    throw TransferServer.Failure.badRequest("Chunked uploads are not supported")
                }
                // Validate before accepting the body so a bad name fails fast.
                _ = try TransferServer.validName(request.query["name"] ?? "")
                receiveUpload(request, initialBody: initialBody)
            case ("GET", "/api/download"):
                try sendFile(server.resolve(request.query["path"] ?? ""))
            default:
                send(404, text: "Not found")
            }
        } catch {
            sendError(error)
        }
    }

    // MARK: Upload streaming

    private func receiveUpload(_ request: Request, initialBody: Data) {
        let temp = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else { return send(500, text: "Cannot create file") }
        let expected = request.contentLength
        var received = 0

        func finish(_ error: Error?) {
            try? handle.close()
            if let error {
                try? FileManager.default.removeItem(at: temp)
                return sendError(error)
            }
            do {
                let saved = try server.acceptUpload(temp, folder: request.query["path"] ?? "", name: request.query["name"] ?? "")
                server.notifyChanged()
                send(200, json: ["ok": true, "name": saved] as [String: any Encodable & Sendable])
            } catch {
                try? FileManager.default.removeItem(at: temp)
                sendError(error)
            }
        }

        func write(_ data: Data) -> Bool {
            do { try handle.write(contentsOf: data) } catch { finish(error); return false }
            received += data.count
            return true
        }

        func next() {
            if received >= expected { return finish(nil) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty, !write(data) { return }
                if let error { return finish(error) }
                if received >= expected { return finish(nil) }
                if isComplete { return finish(TransferServer.Failure.badRequest("Upload interrupted")) }
                next()
            }
        }

        if !initialBody.isEmpty, !write(initialBody.prefix(max(0, expected))) { return }
        next()
    }

    // MARK: Responses

    private func sendFile(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { throw TransferServer.Failure.notFound }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let filename = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "book"
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Length: \(size)\r
        Content-Disposition: attachment; filename*=UTF-8''\(filename)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in sendChunks(handle) })
    }

    private func sendChunks(_ handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            return connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { try? handle.close(); connection.cancel() } else { sendChunks(handle) }
        })
    }

    private func sendError(_ error: Error) {
        switch error {
        case TransferServer.Failure.badRequest(let m): send(400, json: ["error": m])
        case TransferServer.Failure.notFound: send(404, json: ["error": "Not found"])
        case TransferServer.Failure.conflict(let m): send(409, json: ["error": m])
        case TransferServer.Failure.unsupported(let m): send(415, json: ["error": m])
        default: send(500, json: ["error": error.localizedDescription])
        }
    }

    private func send(_ status: Int, json: [String: any Encodable & Sendable]) {
        let body = (try? JSONEncoder().encode(AnyEncodableDictionary(json))) ?? Data("{}".utf8)
        send(status, body: body, type: "application/json")
    }

    private func send(_ status: Int, text: String) {
        send(status, body: Data(text.utf8), type: "text/plain; charset=utf-8")
    }

    private func send(_ status: Int, body: Data, type: String) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict", 415: "Unsupported Media Type"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

private struct AnyEncodableDictionary: Encodable {
    let values: [String: any Encodable & Sendable]
    init(_ values: [String: any Encodable & Sendable]) { self.values = values }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (key, value) in values { try container.encode(value, forKey: Key(stringValue: key)) }
    }
}
