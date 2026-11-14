import ReaderCore
import SwiftUI

/// "Suggest an Improvement" on the Mac: a note appended to iCloud Drive › Scriptorium › Improvement notes.md,
/// like the iPad's (developer builds only).
struct MacImprovementNote: View {
    let context: String
    /// Library-relative path of the open book.
    var file: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggest an Improvement").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 440, height: 160)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What could be better? Bugs, ideas, wishes…").foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .border(.separator)
            Text("Noted at: \(context)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(20)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let note = text, context = context, file = file
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let device = "Mac, macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try ImprovementNotes(file: InboxLocation.improvementNotesFile())
                    .add(note, context: context, file: file, build: build, device: device)
            }.value
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
