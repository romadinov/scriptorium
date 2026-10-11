import ReaderCore
import SwiftUI

@main
struct ReaderApp: App {
    @State private var library = LibraryStore()
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(settings)
                .onOpenURL { url in
                    if let book = library.importFiles([url]).first { library.open(book) }
                }
        }
    }
}
