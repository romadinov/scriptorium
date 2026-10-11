import Foundation
import Testing
@testable import ReaderCore

/// Spins up the real server on a free port and talks to it over HTTP.
@Suite(.serialized) struct TransferServerTests {
    let root: URL
    let server: TransferServer
    let base: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = TransferServer(root: root)
        let port = try await server.start(preferredPort: 0)
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func names(_ folder: String = "") async throws -> [String] {
        let (_, data) = try await call("GET", "/api/list?path=\(folder)")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["entries"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    @Test func servesPage() async throws {
        let (status, data) = try await call("GET", "/")
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Wi-Fi Transfer"))
    }

    @Test func folderLifecycleUploadDownloadMoveDelete() async throws {
        #expect(try await call("POST", "/api/mkdir?path=&name=Physics").0 == 200)
        #expect(try await call("POST", "/api/mkdir?path=&name=Physics").0 == 409)

        // 3 MB body exercises streamed receive across many chunks.
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let up = try await call("PUT", "/api/upload?path=Physics&name=Big%20Book.pdf", body: payload)
        #expect(up.0 == 200)
        #expect(try await names("Physics") == ["Big Book.pdf"])
        #expect(try Data(contentsOf: root.appending(path: "Physics/Big Book.pdf")) == payload)

        // Same name again → renamed, not overwritten.
        _ = try await call("PUT", "/api/upload?path=Physics&name=Big%20Book.pdf", body: Data("x".utf8))
        #expect(try await names("Physics") == ["Big Book 2.pdf", "Big Book.pdf"])

        let (status, downloaded) = try await call("GET", "/api/download?path=Physics/Big%20Book.pdf")
        #expect(status == 200 && downloaded == payload)

        #expect(try await call("POST", "/api/move?from=Physics/Big%20Book%202.pdf&to=").0 == 200)
        #expect(try await names() == ["Physics", "Big Book 2.pdf"])   // folders first

        #expect(try await call("POST", "/api/delete?path=Physics").0 == 200)
        #expect(try await names() == ["Big Book 2.pdf"])
    }

    @Test func rejectsTraversalUnsupportedTypesAndBadNames() async throws {
        #expect(try await call("GET", "/api/list?path=../..").0 == 400)
        #expect(try await call("GET", "/api/download?path=../../etc/passwd").0 == 400)
        #expect(try await call("PUT", "/api/upload?path=&name=evil.sh", body: Data("x".utf8)).0 == 415)
        #expect(try await call("PUT", "/api/upload?path=&name=..%2Fx.pdf", body: Data("x".utf8)).0 == 400)
        #expect(try await call("POST", "/api/delete?path=").0 == 400)
        #expect(try await call("POST", "/api/mkdir?path=&name=.hidden").0 == 400)
        #expect(try await names().isEmpty)
    }

    @Test func listHidesNonBooks() async throws {
        try Data().write(to: root.appending(path: "notes.txt"))
        try Data().write(to: root.appending(path: "Book.fb2.zip"))
        #expect(try await names() == ["Book.fb2.zip"])
    }
}

@Test func uniqueNamesHandleDoubleExtensions() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appending(path: "War.fb2.zip"))
    #expect(LibraryFiles.uniqueURL(for: "War.fb2.zip", in: dir).lastPathComponent == "War 2.fb2.zip")
    #expect(LibraryFiles.uniqueURL(for: "New.pdf", in: dir).lastPathComponent == "New.pdf")
}
