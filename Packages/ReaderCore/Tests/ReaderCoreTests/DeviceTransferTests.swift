import Foundation
import Testing
@testable import ReaderCore

@Test func booksSentToAnotherDeviceArriveInItsLibraryFolders() async throws {
    let cloud = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let directory = DeviceDirectory(root: cloud)
    try directory.register(DeviceInfo(id: "ipad", name: "iPad", kind: .iPad))
    try directory.register(DeviceInfo(id: "mac", name: "MacBook Air", kind: .mac))
    try directory.register(DeviceInfo(id: "old", name: "Old iPhone", kind: .iPhone, lastSeen: Date().addingTimeInterval(-400 * 24 * 3600)))

    // The iPad sees the Mac (not itself, not the long-gone phone).
    #expect(directory.devices(excluding: "ipad").map(\.name) == ["MacBook Air"])

    // iPad sends Physics/Entropy.pdf twice; the second copy doesn't overwrite the first.
    let ipadLibrary = cloud.appending(path: "ipad-lib/Physics")
    try FileManager.default.createDirectory(at: ipadLibrary, withIntermediateDirectories: true)
    let book = ipadLibrary.appending(path: "Entropy.pdf")
    try Data("%PDF-1.4 entropy".utf8).write(to: book)
    let first = try directory.send(book, folder: "Physics", to: "mac")
    let second = try directory.send(book, folder: "Physics", to: "mac")
    #expect(first.lastPathComponent == "Entropy.pdf" && second.lastPathComponent == "Entropy 2.pdf")

    // The Mac imports its transfers into the same folder and the transfer folder empties.
    let macLibrary = cloud.appending(path: "mac-lib")
    try FileManager.default.createDirectory(at: macLibrary, withIntermediateDirectories: true)
    let report = await InboxSync(library: macLibrary, inbox: directory.transfers(for: "mac"), ensureDownloaded: { _ in }).sync()
    #expect(Set(report.imported) == ["Physics/Entropy.pdf", "Physics/Entropy 2.pdf"] || report.duplicates.count == 1)
    #expect(FileManager.default.fileExists(atPath: macLibrary.appending(path: "Physics/Entropy.pdf").path))
    #expect(!InboxSync.hasBooks(in: directory.transfers(for: "mac")))
}
