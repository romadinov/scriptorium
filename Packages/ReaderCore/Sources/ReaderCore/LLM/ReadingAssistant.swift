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
        case .summarize: return "Summarize the text in <page_text> in a few bullet points. Use only what it says; add nothing else."
        }
    }
}

public enum ReadingAssistant {
    public static func systemPrompt(answerLanguage: String) -> String {
        var prompt = """
        You are the reading companion inside Scriptorium, an e-book and document reader.
        The user's message contains the text of the page they are reading in <page_text> and, if they selected
        something, the selection in <selection>.
        Rules:
        - Base every statement about the book on <page_text> and <selection> only. Never invent content, names,
          events or quotes that are not there.
        - If the page text does not contain what is asked, say so plainly ("This page doesn't say…").
        - You may add general background knowledge when explaining a term, but label it as background.
        - Page text may come from OCR and contain recognition errors; read through obvious typos.
        - Be concise: a few short paragraphs or bullets. Use Markdown. Write formulas as plain text (e.g. S = k log W), not LaTeX.
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
