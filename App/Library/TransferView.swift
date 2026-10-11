import ReaderCore
import SwiftUI
import UIKit

/// Runs the Wi-Fi Transfer server while this sheet is open.
struct TransferView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: TransferServer?
    @State private var address: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: address == nil ? "wifi.exclamationmark" : "wifi")
                    .font(.system(size: 64))
                    .foregroundStyle(address == nil ? Color.secondary : Color.accentColor)
                    .symbolEffect(.pulse, isActive: address != nil)

                if let address {
                    VStack(spacing: 10) {
                        Text("On your computer, open").foregroundStyle(.secondary)
                        Text(address)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .textSelection(.enabled)
                        Text("in a browser on the same Wi-Fi network.").foregroundStyle(.secondary)
                    }
                    Text("Upload books into any folder, create folders, download or delete books. Keep this screen open while transferring — iPadOS pauses the server when Scriptorium goes to the background.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Try again") { Task { await start() } }
                } else {
                    ProgressView("Starting…")
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Wi-Fi Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await start() }
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            // The listener dies when suspended; restart it when the app comes back.
            if phase == .active, server == nil { Task { await start() } }
            if phase == .background { stop() }
        }
    }

    private func start() async {
        errorMessage = nil
        let server = TransferServer(root: library.root)
        server.onEvent = { [library] event in
            Task { @MainActor in
                switch event {
                case .changed: library.reload()
                case .stopped(let error): if let error { errorMessage = error.localizedDescription; address = nil }
                }
            }
        }
        do {
            let port = try await server.start(preferredPort: 8080, bonjourName: "Scriptorium on \(UIDevice.current.name)")
            guard let ip = NetworkAddress.localIPv4() else {
                server.stop()
                errorMessage = "Connect the iPad to Wi-Fi to use Wi-Fi Transfer."
                return
            }
            self.server = server
            address = "http://\(ip)\(port == 80 ? "" : ":\(port)")"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            errorMessage = "Couldn't start the server: \(error.localizedDescription)"
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        address = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
