import Foundation

/// Tiny XML tree built with Foundation's XMLParser (XMLDocument isn't available on iOS).
/// Element names are local names (namespace prefixes stripped).
final class XElement {
    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLContent] = []
    weak var parent: XElement?

    enum XMLContent {
        case element(XElement)
        case text(String)
    }

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var elements: [XElement] {
        children.compactMap { if case .element(let e) = $0 { e } else { nil } }
    }

    /// Attribute by local name, ignoring any namespace prefix (`l:href`, `xlink:href` → `href`).
    func attribute(_ local: String) -> String? {
        if let value = attributes[local] { return value }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value
    }

    func child(_ name: String) -> XElement? { elements.first { $0.name == name } }

    func children(_ name: String) -> [XElement] { elements.filter { $0.name == name } }

    /// Depth-first search.
    func descendants(_ name: String) -> [XElement] {
        elements.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    func firstDescendant(_ name: String) -> XElement? {
        for element in elements {
            if element.name == name { return element }
            if let found = element.firstDescendant(name) { return found }
        }
        return nil
    }

    /// All text inside, whitespace collapsed.
    var text: String {
        var out = ""
        collectText(into: &out)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func collectText(into out: inout String) {
        for child in children {
            switch child {
            case .text(let t): out += t
            case .element(let e): e.collectText(into: &out); out += " "
            }
        }
    }

    fileprivate func append(_ content: XMLContent) {
        if case .text(let new) = content, case .text(let old)? = children.last {
            children[children.count - 1] = .text(old + new)
        } else {
            children.append(content)
        }
    }
}

enum MiniXML {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { "XML: \(message)" }
    }

    static func parse(_ data: Data) throws -> XElement {
        let delegate = Builder()
        let parser = XMLParser(data: replacingHTMLEntities(data))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        // A failed parse leaves a truncated tree; reject it so callers fall back to tag stripping.
        guard parser.parse(), let root = delegate.root else {
            throw ParseError(message: parser.parserError?.localizedDescription ?? "no root element")
        }
        return root
    }

    /// XHTML chapters use HTML named entities (`&nbsp;`) that plain XML doesn't declare, and
    /// XMLParser aborts on them. Rewrite the common ones as numeric character references.
    static func replacingHTMLEntities(_ data: Data) -> Data {
        guard data.range(of: Data("&".utf8)) != nil, let text = String(data: data, encoding: .utf8) else { return data }
        let regex = #/&([A-Za-z][A-Za-z0-9]*);/#
        let replaced = text.replacing(regex) { match in
            let name = String(match.1)
            guard let scalar = htmlEntities[name]?.unicodeScalars.first else { return String(match.0) }
            return "&#\(scalar.value);"
        }
        return Data(replaced.utf8)
    }

    static let htmlEntities: [String: String] = [
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "bdquo": "„", "copy": "©", "reg": "®",
        "shy": "\u{00AD}", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwnj": "\u{200C}",
        "middot": "·", "bull": "•", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±", "minus": "−",
        "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡", "prime": "′", "Prime": "″", "euro": "€",
        "pound": "£", "iexcl": "¡", "iquest": "¿", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ", "omega": "ω",
        "larr": "←", "rarr": "→", "le": "≤", "ge": "≥", "ne": "≠", "infin": "∞",
    ]

    static func parse(contentsOf url: URL) throws -> XElement {
        try parse(Data(contentsOf: url))
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XElement?
        private var stack: [XElement] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let element = XElement(name: name, attributes: attributes)
            if let parent = stack.last {
                element.parent = parent
                parent.append(.element(element))
            } else if root == nil {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            stack.last?.append(.text(String(decoding: block, as: UTF8.self)))
        }
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
