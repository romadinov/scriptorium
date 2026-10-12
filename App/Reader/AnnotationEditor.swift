import PencilKit
import ReaderCore
import SwiftUI

/// Edits the note on a highlight or page: typed text, an Apple Pencil (or finger) drawing, or both.
struct AnnotationEditor: View {
    let model: ReaderModel
    let target: AnnotationTarget
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case text = "Text", drawing = "Drawing" }

    @State private var mode: Mode
    @State private var note: String
    @State private var drawing = PKDrawing()
    @State private var drawingChanged = false
    @State private var loadingDrawing: Bool
    @FocusState private var textFocused: Bool

    init(model: ReaderModel, target: AnnotationTarget) {
        self.model = model
        self.target = target
        let item = target.item
        _note = State(initialValue: item.note ?? "")
        _loadingDrawing = State(initialValue: item.drawingID != nil)
        // Open on whatever the note already has; a new note starts with text.
        _mode = State(initialValue: item.drawingID != nil && !item.hasNote ? .drawing : .text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(subject)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    Picker("Note type", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode == .text ? "text.alignleft" : "pencil.tip").tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    // Up here, not in a bottom bar: the Pencil tool palette covers the bottom of the sheet.
                    if mode == .drawing && !drawing.strokes.isEmpty {
                        Button("Clear Drawing", systemImage: "trash", role: .destructive) {
                            drawing = PKDrawing()
                            drawingChanged = true
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                switch mode {
                case .text:
                    TextEditor(text: $note)
                        .focused($textFocused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.background.secondary, in: .rect(cornerRadius: 12))
                        .accessibilityIdentifier("annotation.text")
                        .onAppear { if note.isEmpty { textFocused = true } }
                case .drawing:
                    ZStack {
                        PencilCanvas(drawing: $drawing, onChange: { drawingChanged = true })
                            .accessibilityIdentifier("annotation.canvas")
                        if loadingDrawing { ProgressView() }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(loadingDrawing)
                }
            }
        }
        // Clear explicitly: if `annotating` kept this target, setting it again (e.g. from the page-note
        // pill) would be "no change" and the sheet wouldn't reopen.
        .onDisappear { if model.annotating?.id == target.id { model.annotating = nil } }
        .task {
            guard let id = target.item.drawingID else { return }
            if let data = await model.loadDrawing(id), let stored = try? PKDrawing(data: data) {
                drawing = stored
            }
            loadingDrawing = false
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

    private func save() {
        let change: (data: Data, png: Data?)??
        if !drawingChanged {
            change = nil
        } else if drawing.strokes.isEmpty {
            change = .some(nil)
        } else {
            change = .some((drawing.dataRepresentation(), Self.png(of: drawing)))
        }
        let target = target, note = note, model = model
        Task { await model.saveAnnotation(target, note: note, drawing: change) }
        dismiss()
    }

    /// A light-mode picture of the drawing for the Markdown export (ink adapts to dark mode otherwise).
    static func png(of drawing: PKDrawing) -> Data? {
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard !bounds.isEmpty else { return nil }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: bounds, scale: 2)
            image = UIGraphicsImageRenderer(size: bounds.size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                ink.draw(at: .zero)
            }
        }
        return image?.pngData()
    }
}

/// PencilKit canvas with the system tool picker. Fingers draw too, so it works without a Pencil.
struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvas.delegate = context.coordinator
        let picker = context.coordinator.toolPicker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing != drawing {
            context.coordinator.updating = true
            canvas.drawing = drawing
            context.coordinator.updating = false
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvas
        let toolPicker = PKToolPicker()
        var updating = false

        init(_ parent: PencilCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard !updating else { return }
            parent.drawing = canvas.drawing
            parent.onChange()
        }
    }
}
