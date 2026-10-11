import ReaderCore
import SwiftUI
import UIKit

/// "Suggest an improvement": a note saved to iCloud Drive › Scriptorium › Improvement notes.md,
/// with where it was written and (optionally) a screenshot of that moment.
struct ImprovementNoteView: View {
    let context: String
    let screenshot: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attach = true
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What could be better? Bugs, ideas, wishes…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                } footer: {
                    Text("Noted at: \(context)")
                }
                if let screenshot {
                    Section {
                        Toggle("Attach screenshot", isOn: $attach)
                        if attach {
                            Image(uiImage: screenshot).resizable().scaledToFit().frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Suggest an Improvement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let note = text, context = context
        let png = attach ? screenshot?.pngData() : nil
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let device = "\(UIDevice.current.model), iPadOS/iOS \(UIDevice.current.systemVersion)"
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try ImprovementNotes(file: InboxLocation.improvementNotesFile())
                    .add(note, context: context, build: build, device: device, screenshot: png)
            }.value
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

enum Screenshot {
    /// The app's current screen (taken before a sheet covers it).
    @MainActor static func capture() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
    }
}

/// Shared state for presenting the note form from anywhere: grabs the screenshot first, then shows the sheet.
@MainActor @Observable
final class ImprovementNoteRequest {
    struct Pending: Identifiable {
        let id = UUID()
        let context: String
        let screenshot: UIImage?
    }

    var pending: Pending?

    func start(context: String) {
        // Let the menu that triggered this close first, so the screenshot shows the page, not the menu.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            pending = Pending(context: context, screenshot: Screenshot.capture())
        }
    }
}
