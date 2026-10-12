import PencilKit
import ReaderCore
import SwiftUI

/// Note on a highlight or page. Text is edited here; drawings (made with Apple Pencil on the iPad) are shown
/// and can be removed.
struct MacAnnotationEditor: View {
    let model: ReaderModel
    let target: AnnotationTarget
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var drawing: NSImage?
    @State private var removeDrawing = false

    init(model: ReaderModel, target: AnnotationTarget) {
        self.model = model
        self.target = target
        _note = State(initialValue: target.item.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(subject).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            TextEditor(text: $note)
                .font(.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            if let drawing, !removeDrawing {
                HStack(alignment: .top) {
                    Image(nsImage: drawing).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 180)
                        .background(.white, in: .rect(cornerRadius: 8))
                    Button("Remove Drawing", systemImage: "trash", role: .destructive) { removeDrawing = true }
                }
            } else if target.item.drawingID == nil {
                Text("Drawings can be added with Apple Pencil in Scriptorium on iPad.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            guard let id = target.item.drawingID, let data = await model.loadDrawing(id),
                  let pk = try? PKDrawing(data: data) else { return }
            let bounds = pk.bounds.insetBy(dx: -12, dy: -12)
            drawing = pk.image(from: bounds, scale: 2)
        }
    }

    private var title: String {
        switch target {
        case .highlight: target.item.hasAnnotation ? "Edit Note" : "Note on Highlight"
        case .bookmark(let b): "Note on \(b.label)"
        }
    }

    private var subject: String {
        switch target {
        case .highlight(let h): "“\(h.text)”"
        case .bookmark(let b): b.snippet
        }
    }

    private func close() {
        if model.annotating?.id == target.id { model.annotating = nil }
        dismiss()
    }

    private func save() {
        let change: (data: Data, png: Data?)?? = removeDrawing ? .some(nil) : nil
        let target = target, note = note, model = model
        Task { await model.saveAnnotation(target, note: note, drawing: change) }
        close()
    }
}
