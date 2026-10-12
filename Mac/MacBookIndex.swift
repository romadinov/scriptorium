import ReaderCore
import SwiftUI

/// Sidebar of a book window: Contents | Bookmarks | Highlights.
struct MacBookIndex: View {
    enum Tab: Hashable { case contents, bookmarks, highlights }

    let model: ReaderModel
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Contents").tag(Tab.contents)
                Text("Bookmarks").tag(Tab.bookmarks)
                Text("Highlights").tag(Tab.highlights)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            switch tab {
            case .contents: contents
            case .bookmarks: bookmarks
            case .highlights: highlights
            }
        }
    }

    @ViewBuilder
    private var contents: some View {
        if model.source.outline.isEmpty {
            ContentUnavailableView("No Contents", systemImage: "list.bullet",
                                   description: Text("This book has no table of contents. Use Go › Go to Page… (⌥⌘G)."))
        } else {
            List {
                OutlineGroup(model.source.outline, children: \.childrenOrNil) { item in
                    Button {
                        if let page = item.pageIndex { model.go(to: page) }
                    } label: {
                        HStack {
                            Text(item.title).lineLimit(2)
                            Spacer()
                            if let page = item.pageIndex { Text("\(page + 1)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.pageIndex == nil)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var bookmarks: some View {
        if model.bookmarks.isEmpty {
            ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                   description: Text("Bookmark a page with ⌘D, or add a Page Note."))
        } else {
            List {
                ForEach(model.bookmarks) { mark in
                    Button { model.open(mark) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mark.hasAnnotation ? "note.text" : "bookmark.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("p. \(model.page(of: mark))").font(.headline)
                                Text(mark.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                MacAnnotationSummary(item: mark)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(mark.hasAnnotation ? "Edit Note…" : "Add Note…") { model.annotating = .bookmark(mark) }
                        Button("Remove Bookmark", role: .destructive) { Task { await model.removeBookmark(mark) } }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var highlights: some View {
        if model.highlights.isEmpty {
            ContentUnavailableView("No Highlights", systemImage: "highlighter",
                                   description: Text("Select text, then right-click › Highlight (or ⌃⌘H)."))
        } else {
            List {
                ForEach(model.highlights) { highlight in
                    Button { model.reveal(highlight) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(highlight.color.swiftUI).frame(width: 4)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(highlight.text).lineLimit(4)
                                Text(model.locationLabel(highlight.location)).font(.caption).foregroundStyle(.secondary)
                                MacAnnotationSummary(item: highlight)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(highlight.hasAnnotation ? "Edit Note…" : "Add Note…") { model.annotating = .highlight(highlight) }
                        Menu("Color") {
                            ForEach(Highlight.Color.allCases, id: \.self) { color in
                                Button(color.rawValue.capitalized) { Task { await model.recolor(highlight, to: color) } }
                            }
                        }
                        Button("Remove Highlight", role: .destructive) { Task { await model.removeHighlight(highlight) } }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct MacAnnotationSummary: View {
    let item: any Annotatable

    var body: some View {
        if item.hasAnnotation {
            HStack(spacing: 4) {
                if item.drawingID != nil { Image(systemName: "scribble.variable") }
                Text(item.hasNote ? (item.note ?? "") : "Drawing").lineLimit(3)
            }
            .font(.callout).foregroundStyle(.orange)
        }
    }
}

extension OutlineItem {
    var childrenOrNil: [OutlineItem]? { children.isEmpty ? nil : children }
}

extension Highlight.Color {
    var swiftUI: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
}
