import Foundation
import SwiftSoup

/// Reads a web page the way the PDF importer reads a page: prose becomes text, while figures,
/// code, tables and display equations are kept as pictures of the rendered page.
///
/// Elements that do not read as prose are tagged in the HTML and replaced in the text by
/// figure markers. The tagged page is then rendered by `WebSnapshotter`, and markers are turned
/// into word positions by `PDFTextExtractor.placingFigures`. Sidenotes and footnotes are moved
/// to the end of the sentence that refers to them, so they are read in context without
/// interrupting it.
enum WebArticleExtractor {
    static let figureAttribute = "data-rr-figure"

    struct Request {
        var kind: SectionFigure.Kind
        var text: String
        /// Pixels per CSS pixel; inline formulas are small on the page and get more.
        var scale: Double
    }

    struct Extraction {
        /// Article text with marker lines where figures belong.
        var text: String
        /// Page HTML with figure elements tagged by `figureAttribute`, for rendering.
        var renderHTML: String
        /// Figures by marker number; only numbers whose marker survived in `text` are kept.
        var requests: [Int: Request]
    }

    private static let candidates = [
        "figure", "pre", "table", "img", "svg", "canvas", "video",
        ".katex-display", ".katex", ".mwe-math-element", "mjx-container", "math"
    ].joined(separator: ", ")

    static func extract(_ html: String, article: Bool) -> Extraction? {
        guard let document = try? SwiftSoup.parse(html) else { return nil }
        loadLazyImages(in: document)
        moveNotesAfterSentences(in: document)

        var requests: [Int: Request] = [:]
        var marked: [(Element, Int)] = []
        for element in (try? document.select(candidates).array()) ?? [] where !hasMarkedAncestor(element) {
            guard let request = request(for: element) else { continue }
            let number = marked.count
            _ = try? element.attr(figureAttribute, "\(number)")
            requests[number] = request
            marked.append((element, number))
        }
        let renderHTML = (try? document.outerHtml()) ?? html

        for (element, number) in marked {
            let marker = PDFLayoutAnalyzer.markerPrefix + "\(number)"
            if isInline(element) {
                // Short inline math reads fine as a word; longer formulas stop playback as figures.
                let linear = linearMath(element)
                if !needsPicture(element, linear: linear) {
                    requests[number] = nil
                    _ = try? element.before(TextNode(" \(linear.filter { !$0.isWhitespace }) ", ""))
                } else {
                    _ = try? element.before(TextNode(" \(marker) ", ""))
                }
            } else {
                let caption = (try? element.select("figcaption").first()?.text()) ?? ""
                _ = try? element.before("<p>\(marker)</p>" + (caption.isEmpty ? "" : "<p>\(Entities.escape(caption))</p>"))
            }
            _ = try? element.remove()
        }

        var text: String
        if article {
            let root = HTMLTextExtractor.articleRoot(of: document)
            text = HTMLTextExtractor.text(from: root)
            if let lead = leadImage(before: root, requests: requests) {
                text = PDFLayoutAnalyzer.markerPrefix + "\(lead)\n\n" + text
            }
        } else {
            text = HTMLTextExtractor.strippedText(of: document)
        }
        let kept = Set(TextProcessor.tokenize(text).compactMap { token -> Int? in
            token.hasPrefix(PDFLayoutAnalyzer.markerPrefix) ? Int(token.dropFirst(PDFLayoutAnalyzer.markerPrefix.count)) : nil
        })
        return Extraction(text: text, renderHTML: renderHTML, requests: requests.filter { kept.contains($0.key) })
    }

    /// Builds the reading sections, with rendered figures placed.
    static func sections(from extraction: Extraction, images: [Int: Data], fallbackTitle: String) -> [BookSection] {
        let count = (extraction.requests.keys.max() ?? -1) + 1
        let figures = (0..<count).map { number -> PDFLayoutAnalyzer.PageFigure in
            let request = extraction.requests[number]
            return PDFLayoutAnalyzer.PageFigure(kind: request?.kind ?? .image, imageData: images[number] ?? Data(), text: request?.text ?? "")
        }
        // Figures whose element could not be rendered and has no text to show are dropped.
        let unusable = Set((0..<count).filter { figures[$0].imageData.isEmpty && figures[$0].text.isEmpty })
        var text = extraction.text
        for number in unusable {
            text = text.replacingOccurrences(of: PDFLayoutAnalyzer.markerPrefix + "\(number)" + #"\b"#, with: "", options: .regularExpression)
        }
        return PDFTextExtractor.placingFigures(TextProcessor.sections(from: text, fallbackTitle: fallbackTitle), figures: figures)
    }

    /// A cover image often sits beside the title, outside the element holding the article body.
    /// Returns its marker number when one comes before `root` within the page's main content.
    private static func leadImage(before root: Element, requests: [Int: Request]) -> Int? {
        var current: Element = root
        while let parent = current.parent(), parent.tagName() != "body", parent.tagName() != "html" {
            for sibling in parent.children().array() {
                if sibling === current { break }
                let text = (try? sibling.text()) ?? ""
                for token in TextProcessor.tokenize(text) where token.hasPrefix(PDFLayoutAnalyzer.markerPrefix) {
                    if let number = Int(token.dropFirst(PDFLayoutAnalyzer.markerPrefix.count)), requests[number]?.kind == .image {
                        return number
                    }
                }
            }
            current = parent
        }
        return nil
    }

    // MARK: Page cleanup

    private static func loadLazyImages(in document: Document) {
        for image in (try? document.select("img").array()) ?? [] {
            _ = try? image.removeAttr("loading")
            for attribute in ["data-src", "data-original", "data-lazy-src"] {
                if let source = try? image.attr(attribute), !source.isEmpty {
                    _ = try? image.attr("src", source)
                }
            }
        }
    }

    /// Sidenotes and footnote references sit in the middle of sentences. Each note is moved
    /// to the end of the sentence that refers to it, as `[Note: …]`, and the footnote list
    /// it came from is removed.
    private static func moveNotesAfterSentences(in document: Document) {
        let placeholder = "\u{E000}"
        var notes: [(anchor: TextNode, text: String)] = []
        func take(_ note: Element, anchor: Element) {
            for math in (try? note.select(".katex, .mwe-math-element, mjx-container, math").array()) ?? [] where math.parent() != nil {
                _ = try? math.before(TextNode(linearMath(math), ""))
                _ = try? math.remove()
            }
            _ = try? note.select("a.footnote-backref, [role=doc-backlink]").remove()
            let text = TextProcessor.normalizedText((try? note.text()) ?? "")
            guard !text.isEmpty else { return }
            let marker = TextNode(placeholder, "")
            _ = try? anchor.before(marker)
            notes.append((marker, text))
        }

        for note in (try? document.select(".sidenote, .marginnote, .margin-note").array()) ?? [] {
            take(note, anchor: note)
            _ = try? note.remove()
        }
        // Classic footnotes: a numbered link in the text pointing at an item in a list at the end.
        var listed: [Element] = []
        for reference in (try? document.select("sup, a.footnote-ref, [role=doc-noteref]").array()) ?? [] where reference.parent() != nil {
            guard let link = reference.tagName() == "a" ? reference : try? reference.select("a[href^=#]").first(),
                  ((try? link.text()) ?? "").range(of: #"^\[?\d+\]?$"#, options: .regularExpression) != nil else { continue }
            let id = String(((try? link.attr("href")) ?? "").dropFirst())
            if !id.isEmpty, let target = try? document.getElementById(id), !hasAncestor(reference, target) {
                take(target, anchor: reference)
                listed.append(target)
            }
            _ = try? reference.remove()
        }
        for item in listed { _ = try? item.remove() }
        _ = try? document.select(".footnotes:not(:has(li)), section[role=doc-endnotes]:not(:has(li))").remove()
        _ = try? document.select("label.margin-toggle, input.margin-toggle, .sidenote-number").remove()

        for note in notes.reversed() {
            place(note.text, at: note.anchor)
        }
    }

    /// Puts `note` after the first sentence end that follows `anchor` in its paragraph,
    /// or at the end of the paragraph.
    private static func place(_ note: String, at anchor: TextNode) {
        defer { _ = try? anchor.remove() }
        let inserted = " [Note: \(note)] "
        // A note placed right after a sentence already belongs where it is.
        if let previous = anchor.previousSibling() as? TextNode,
           previous.getWholeText().range(of: #"[.!?][”’"')\]]*\s*$"#, options: .regularExpression) != nil {
            _ = try? anchor.before(TextNode(inserted, ""))
            return
        }
        var block = anchor.parent() as? Element
        while let current = block, !["p", "li", "blockquote", "dd", "td", "figcaption", "div", "section", "article", "body"].contains(current.tagName()) {
            block = current.parent()
        }
        guard let block else { return }
        var passed = false
        for node in descendantTextNodes(block) where node.parent() != nil {
            if node === anchor { passed = true; continue }
            guard passed, !insideMath(node) else { continue }
            let text = node.getWholeText()
            guard let end = text.range(of: #"[.!?][”’"')\]]*(?=\s|$)"#, options: .regularExpression) else { continue }
            let head = String(text[..<end.upperBound])
            let tail = String(text[end.upperBound...])
            node.text(head)
            _ = try? node.after(TextNode(inserted + tail, ""))
            return
        }
        _ = try? block.appendChild(TextNode(inserted, ""))
    }

    /// Text nodes of `element` in document order.
    private static func descendantTextNodes(_ element: Element) -> [TextNode] {
        var nodes: [TextNode] = []
        for child in element.getChildNodes() {
            if let text = child as? TextNode {
                nodes.append(text)
            } else if let child = child as? Element {
                nodes += descendantTextNodes(child)
            }
        }
        return nodes
    }

    private static func insideMath(_ node: Node) -> Bool {
        var parent = node.parent()
        while let current = parent as? Element {
            if isMath(current) || current.tagName() == "code" { return true }
            parent = current.parent()
        }
        return false
    }

    private static func hasAncestor(_ node: Node, _ ancestor: Element) -> Bool {
        var parent = node.parent()
        while let current = parent {
            if current === ancestor { return true }
            parent = current.parent()
        }
        return false
    }

    // MARK: Figures

    private static func hasMarkedAncestor(_ element: Element) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if current.hasAttr(figureAttribute) { return true }
            parent = current.parent()
        }
        return false
    }

    private static func isMath(_ element: Element) -> Bool {
        ["math", "mjx-container"].contains(element.tagName()) || element.hasClass("katex") || element.hasClass("katex-display") || element.hasClass("mwe-math-element")
    }

    private static func isInline(_ element: Element) -> Bool {
        guard isMath(element) else { return false }
        if element.hasClass("katex-display") || value(element, "display") == "block" || value(element, "display") == "true" { return false }
        if (try? element.select("math[display=block], .mwe-math-fallback-image-display").isEmpty()) == false { return false }
        return true
    }

    private static func request(for element: Element) -> Request? {
        let tag = element.tagName()
        if isMath(element) {
            return Request(kind: .formula, text: linearMath(element), scale: isInline(element) ? 4 : 3)
        }
        let text = TextProcessor.normalizedText((try? element.text()) ?? "")
        switch tag {
        case "pre":
            let code = (try? element.text(trimAndNormaliseWhitespace: false)) ?? text
            return Request(kind: .code, text: code.trimmingCharacters(in: .newlines), scale: 2)
        case "table":
            // Tables used for page layout hold prose, not data.
            guard TextProcessor.tokenize(text).count < 300, (try? element.select("p, table table").isEmpty()) != false else { return nil }
            return Request(kind: .table, text: text, scale: 2)
        case "img", "svg", "canvas", "video":
            guard !isSmall(element), !isInsideControl(element) else { return nil }
            return Request(kind: .image, text: value(element, "alt"), scale: 2)
        case "figure":
            let hasPicture = (try? element.select("img, svg, canvas, video, picture").isEmpty()) == false
            if !hasPicture, (try? element.select("pre").isEmpty()) == false {
                return Request(kind: .code, text: text, scale: 2)
            }
            if !hasPicture, (try? element.select("table").isEmpty()) == false {
                return Request(kind: .table, text: text, scale: 2)
            }
            if !hasPicture, (try? element.select(".katex-display, math").isEmpty()) == false {
                return Request(kind: .formula, text: text, scale: 3)
            }
            // A figure of plain text, such as a pull quote, is read as prose.
            guard hasPicture || TextProcessor.tokenize(text).count < 40 else { return nil }
            let caption = (try? element.select("figcaption").first()?.text()) ?? ""
            return Request(kind: .image, text: caption, scale: 2)
        default:
            return nil
        }
    }

    private static func value(_ element: Element, _ attribute: String) -> String {
        (try? element.attr(attribute)) ?? ""
    }

    private static func isSmall(_ element: Element) -> Bool {
        for attribute in ["width", "height"] {
            if let value = Double(value(element, attribute).replacingOccurrences(of: "px", with: "")), value < 48 { return true }
        }
        return false
    }

    private static func isInsideControl(_ element: Element) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if ["a", "button", "nav", "header", "footer"].contains(current.tagName()) { return true }
            parent = current.parent()
        }
        return false
    }

    private static func needsPicture(_ element: Element, linear: String) -> Bool {
        let structured = (try? element.select("mfrac, msqrt, mroot, munderover, mtable").isEmpty()) == false
        return structured || linear.count > 14
    }

    // MARK: MathML

    /// One-line reading of a formula from its MathML, such as `π_θ(x)` for `\pi_\theta(x)`.
    static func linearMath(_ element: Element) -> String {
        if let math = try? element.select("math").first() {
            return linear(math)
        }
        // Formulas without MathML, such as image fallbacks, keep their alternative text.
        let alt = (try? element.select("img[alt]").first()?.attr("alt")) ?? ""
        return alt.isEmpty ? TextProcessor.normalizedText((try? element.text()) ?? "") : alt
    }

    private static func linear(_ element: Element) -> String {
        let children = element.children().array()
        func part(_ index: Int) -> String { children.indices.contains(index) ? linear(children[index]) : "" }
        switch element.tagName() {
        case "annotation", "annotation-xml":
            return ""
        case "mi", "mn", "mo", "mtext", "ms":
            return (try? element.text()) ?? ""
        case "mspace":
            return " "
        case "msub":
            return part(0) + subscripted(part(1))
        case "msup":
            return part(0) + superscripted(part(1))
        case "msubsup":
            return part(0) + subscripted(part(1)) + superscripted(part(2))
        case "munder":
            return part(0) + subscripted(part(1))
        case "mover":
            // Accents such as hats and bars sit over the base; anything else reads as a power.
            let over = part(1)
            return ["^", "ˆ", "¯", "‾", "~", "˜", "˙", "→", "⃗", "."].contains(over) ? part(0) : part(0) + superscripted(over)
        case "munderover":
            return part(0) + subscripted(part(1)) + superscripted(part(2))
        case "mfrac":
            return grouped(part(0)) + "/" + grouped(part(1))
        case "msqrt":
            return "√" + grouped(children.map(linear).joined())
        case "mroot":
            return "√" + grouped(part(0))
        default:
            return children.map(linear).joined()
        }
    }

    private static func grouped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 1 { return trimmed }
        if let first = trimmed.first, let last = trimmed.last, "([{".contains(first), ")]}".contains(last) { return trimmed }
        return trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) ? trimmed : "(\(trimmed))"
    }

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ"
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "*": "*", "∗": "*", "′": "′",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "T": "ᵀ", "θ": "ᶿ"
    ]

    private static func subscripted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let mapped = trimmed.compactMap { subscripts[$0] }
        return mapped.count == trimmed.count ? String(mapped) : "_" + grouped(trimmed)
    }

    private static func superscripted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let mapped = trimmed.compactMap { superscripts[$0] }
        return mapped.count == trimmed.count ? String(mapped) : "^" + grouped(trimmed)
    }
}
