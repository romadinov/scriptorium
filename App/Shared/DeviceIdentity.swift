import Foundation
import ReaderCore
#if canImport(UIKit)
import UIKit
#endif

/// A stable id for this install and a name people recognise ("iPad", "Alexey's MacBook Air"), used to
/// tell devices apart in synced reading positions.
enum DeviceIdentity {
    static let id: String = {
        if let existing = UserDefaults.standard.string(forKey: "deviceID") { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "deviceID")
        return new
    }()

    @MainActor static var kind: DeviceInfo.Kind {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    @MainActor static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model
        #endif
    }
}

extension PositionStore {
    static let shared = PositionStore(containerIdentifier: "iCloud.com.romadinov.reader")
}
