import ReaderCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        InboxBackgroundImport.register()   // BGTaskScheduler requires registration during launch
        return true
    }
}

@main
struct ReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LibraryStore()
    @State private var settings = SettingsStore()
    @State private var noteRequest = ImprovementNoteRequest()

    var body: some Scene {
        @Bindable var noteRequest = noteRequest
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(settings)
                .environment(noteRequest)
                .sheet(item: $noteRequest.pending) { pending in
                    ImprovementNoteView(context: pending.context, file: pending.file, screenshot: pending.screenshot)
                }
                .onOpenURL { url in
                    if let link = DeepLink(url: url) {
                        Task { await library.open(link) }
                    } else if let book = library.importFiles([url]).first {
                        library.open(book)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: library.startWatchingInbox()
                    case .background:
                        library.stopWatchingInbox()
                        InboxBackgroundImport.schedule()
                    default: break
                    }
                }
        }
    }
}
