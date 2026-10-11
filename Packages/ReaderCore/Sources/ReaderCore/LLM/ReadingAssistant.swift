import Foundation

/// What the reader was looking at when asking.
public struct ReadingContext: Sendable {
    public var documentTitle: String
    public var pageIndex: Int
    public var selection: String?
    public var surroundingText: String

    public init(documentTitle: String, pageIndex: Int, selection: String?, surroundingText: String) {
        self.documentTitle = documentTitle
        self.pageIndex = pageIndex
        self.selection = selection
        self.surroundingText = surroundingText
    }
}

/// Canned actions offered on a text selection.
public enum QuickAction: String, CaseIterable, Identifiable, Sendable {
    case explain, define, translate, summarize

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explain: "Explain"
        case .define: "Define in context"
        case .translate: "Translate"
        case .summarize: "Summarize page"
        }
    }

    public var systemImage: String {
        switch self {
        case .explain: "lightbulb"
        case .define: "character.book.closed"
        case .translate: "translate"
        case .summarize: "text.append"
        }
    }

    public func question(selection: String?, language: String) -> String {
        let lang = language.isEmpty ? "English" : language
        switch self {
        case .explain: return "Explain the selected passage in plain words. What does it mean here and why does it matter?"
        case .define: return "Define the selected word or phrase as it is used in this text. Give the meaning, part of speech, and a short example."
        case .translate: return "Translate the selected text into \(lang). Keep terminology accurate; add a brief note only if something is ambiguous."
        case .summarize: return "Summarize the current page in a few bullet points."
        }
    }
}

public enum ReadingAssistant {
    public static func systemPrompt(answerLanguage: String) -> String {
        var prompt = """
        You are the reading companion inside Scriptorium, an e-book and document reader. The user is reading a document and asks about it.
        Ground answers in the provided page text when it is relevant, and say when you are drawing on general knowledge instead.
        Page text may come from OCR and contain recognition errors — read through obvious typos.
        Be concise: a few short paragraphs or bullets. Use Markdown. Write formulas in LaTeX between $…$.
        """
        if !answerLanguage.isEmpty {
            prompt += "\nAnswer in \(answerLanguage) unless asked otherwise."
        } else {
            prompt += "\nAnswer in the language of the user's question."
        }
        return prompt
    }

    /// First user turn: document context followed by the question.
    public static func firstMessage(question: String, context: ReadingContext) -> String {
        var parts: [String] = []
        parts.append("Document: \(context.documentTitle), current page \(context.pageIndex + 1).")
        if !context.surroundingText.isEmpty {
            parts.append("<page_text>\n\(context.surroundingText)\n</page_text>")
        }
        if let selection = context.selection, !selection.isEmpty {
            parts.append("<selection>\n\(selection)\n</selection>")
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }
}
