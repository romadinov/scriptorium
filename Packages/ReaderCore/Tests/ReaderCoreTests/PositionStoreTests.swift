import Foundation
import Testing
@testable import ReaderCore

@Test func positionsAreSharedPerDeviceAndOfferedOnlyWhenNewerAndElsewhere() async {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = PositionStore(root: root)
    let now = Date()
    await store.save(SyncedPosition(page: 3, progress: 0, label: "p. 4", updated: now.addingTimeInterval(-3600), device: "iPad", deviceID: "ipad"), documentID: "doc")
    await store.save(SyncedPosition(page: 119, progress: 0, label: "p. 120", updated: now, device: "Mac", deviceID: "mac"), documentID: "doc")

    // The iPad sees only the Mac's position, and vice versa.
    let seenByIPad = await store.others(documentID: "doc", excluding: "ipad")
    #expect(seenByIPad.map(\.device) == ["Mac"])
    #expect(await store.others(documentID: "doc", excluding: "mac").map(\.label) == ["p. 4"])

    let mac = seenByIPad[0]
    #expect(mac.shouldOffer(over: 3, 0, savedAt: now.addingTimeInterval(-3600)))     // newer and elsewhere
    #expect(!mac.shouldOffer(over: 119, 0.01, savedAt: nil))                         // same place
    #expect(!mac.shouldOffer(over: 3, 0, savedAt: now.addingTimeInterval(60)))       // local is newer
    #expect(await store.others(documentID: "other", excluding: "ipad").isEmpty)
}
