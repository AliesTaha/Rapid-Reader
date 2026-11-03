import Foundation

public enum TextProcessor {
    public static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{fffc}", with: " ")
            .replacingOccurrences(of: "\u{200b}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func tokenize(_ text: String) -> [String] {
        tokenizedText(text).tokens.map(\.text)
    }

    /// Ranges use UTF-16 offsets in the returned normalized text, as required by AppKit.
    public static func tokenizedText(_ text: String) -> TokenizedText {
        let normalized = normalizedText(text)
        let source = normalized as NSString
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        let tokens = regex.matches(in: normalized, range: NSRange(location: 0, length: source.length)).compactMap { match -> TextToken? in
            let word = source.substring(with: match.range)
            return containsReadableScalar(word) ? TextToken(text: word, range: match.range) : nil
        }
        return TokenizedText(text: normalized, tokens: tokens)
    }

    public static func sections(from text: String, fallbackTitle: String) -> [BookSection] {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else {
            return [BookSection(title: fallbackTitle, text: "")]
        }

        let headingSections = splitByHeadings(normalized)
        if headingSections.count > 1 {
            return headingSections
        }

        let words = tokenize(normalized)
        guard words.count > 1_600 else {
            return [BookSection(title: fallbackTitle, text: normalized)]
        }

        var sections: [BookSection] = []
        var cursor = 0
        var part = 1
        while cursor < words.count {
            let end = min(cursor + 1_200, words.count)
            let chunk = words[cursor..<end].joined(separator: " ")
            sections.append(BookSection(title: "Part \(part)", text: chunk, wordCount: end - cursor))
            cursor = end
            part += 1
        }
        return sections
    }

    public static func cleanedTitle(_ title: String?, fallback: String) -> String {
        let candidate = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return fallback }
        return candidate
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitByHeadings(_ text: String) -> [BookSection] {
        let lines = text.components(separatedBy: .newlines)
        var currentTitle: String?
        var currentLines: [String] = []
        var sections: [BookSection] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHeading(trimmed) {
                if let title = currentTitle, !currentLines.isEmpty {
                    sections.append(BookSection(title: title, text: currentLines.joined(separator: "\n")))
                }
                currentTitle = headingTitle(from: trimmed)
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        if let title = currentTitle, !currentLines.isEmpty {
            sections.append(BookSection(title: title, text: currentLines.joined(separator: "\n")))
        }

        return sections.filter { $0.wordCount > 0 }
    }

    /// Runs of tokens that form one inline expression, such as `distance(a,b− 1):` or
    /// `x = 3`, so the reader can show them whole instead of word by word.
    public static func expressionRuns(in tokens: [String]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var index = 0
        while index < tokens.count {
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            guard isMathToken(tokens[index]) || (tokens[index].count <= 3 && startsWithOperator(next)) || joinsOperands(tokens, at: index + 1) else {
                index += 1
                continue
            }
            var depth = bracketBalance(tokens[index])
            var end = index + 1
            var lastMath = index
            while end < tokens.count, end - index < 16 {
                let token = tokens[end]
                // A token that closes an open bracket finishes the expression, as in `count(k, x)`.
                let closes = depth > 0 && depth + bracketBalance(token) < depth
                let joined = closes || isMathToken(token) || endsWithOperator(tokens[end - 1]) || startsWithOperator(token)
                    || joinsOperands(tokens, at: end) || joinsOperands(tokens, at: end - 1)
                // An open bracket carries a couple of plain words, never a whole sentence.
                guard joined || (depth > 0 && end - lastMath <= 2) else { break }
                if joined { lastMath = end }
                depth = max(0, depth + bracketBalance(token))
                end += 1
            }
            end = lastMath + 1
            // A closing bracket with no opening one means the expression began a little earlier.
            var start = index
            var balance = tokens[start..<end].reduce(0) { $0 + bracketBalance($1) }
            while balance < 0 && start > (runs.last?.upperBound ?? 0) && index - start < 3 {
                start -= 1
                balance += bracketBalance(tokens[start])
            }
            if balance < 0 { start = index }
            let length = tokens[start..<end].reduce(0) { $0 + $1.count }
            if length >= 3 {
                // A lone capital between two pieces is part of the formula, such as the ℙ that
                // comes out as "P" in `P_x,a(·) = P Y(a) ∈ · | X = x`.
                if let last = runs.last, start - last.upperBound == 1,
                   tokens[last.upperBound].range(of: #"^\p{Lu}$"#, options: .regularExpression) != nil {
                    runs[runs.count - 1] = last.lowerBound..<end
                } else {
                    runs.append(start..<end)
                }
            }
            index = end
        }
        return runs
    }

    private static let operators = CharacterSet(charactersIn: "=<>+*/^|∖≤≥≠≈∼≃−±×·⊕⊙∧∨∈∉⊂⊆→←↔⇒⇔")

    private static func isMathToken(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'“”’"))
        guard !core.isEmpty, !core.contains("://") else { return false }
        // Tuples such as (1, 2) or [x, y], and an opening bracket on a short variable such as (i.
        if token.range(of: #"^[(\[{][^\s]*,"#, options: .regularExpression) != nil
            || token.range(of: #"^[(\[{][\p{L}\d]{1,2}$"#, options: .regularExpression) != nil {
            return true
        }
        if core.unicodeScalars.contains(where: { scalar in
            (scalar.properties.generalCategory == .mathSymbol && scalar != "¬") || (0x0391...0x03C9).contains(scalar.value)
                || (0x2200...0x22FF).contains(scalar.value) || (0x2190...0x21FF).contains(scalar.value)
                || (0x1D400...0x1D7FF).contains(scalar.value) || operators.contains(scalar)
        }) {
            return true
        }
        // Function calls and indexing such as f(x), solve(10) or a[i].
        if core.range(of: #"^\p{L}[\p{L}\d]*[(\[].*$"#, options: .regularExpression) != nil
            && core.range(of: #"^\p{L}{4,}\($"#, options: .regularExpression) == nil {
            return true
        }
        // Dimensions such as 5x6 and bracketed variables such as (x).
        return core.range(of: #"^\d+[x×]\d+$"#, options: .regularExpression) != nil
            || core.range(of: #"^[(\[{][\p{L}\d]{1,2}[)\]}]$"#, options: .regularExpression) != nil
    }

    /// "&" and "\" are operators between numbers and one-letter names, as in "22 & 26" or
    /// "A \ B", and words elsewhere, as in "Tom & Jerry".
    private static func joinsOperands(_ tokens: [String], at index: Int) -> Bool {
        guard index > 0, index + 1 < tokens.count, tokens[index] == "&" || tokens[index] == "\\" else { return false }
        func operand(_ token: String) -> Bool {
            token.range(of: #"^[(\[{]*(\d+|\p{L})([)\]},.;:]*$|[=<>+−·×|^])"#, options: .regularExpression) != nil
        }
        return operand(tokens[index - 1]) && operand(tokens[index + 1])
    }

    private static func startsWithOperator(_ token: String) -> Bool {
        token.unicodeScalars.first.map(operators.contains) ?? false
    }

    private static func endsWithOperator(_ token: String) -> Bool {
        guard !token.hasSuffix("++") else { return false }
        return token.unicodeScalars.last.map { operators.contains($0) || "([{".unicodeScalars.contains($0) } ?? false
    }

    private static func bracketBalance(_ token: String) -> Int {
        token.reduce(0) { count, character in
            "([{".contains(character) ? count + 1 : ")]}".contains(character) ? count - 1 : count
        }
    }

    /// Words, numbers and mathematical symbols are read; dashes, bullets and other punctuation
    /// standing alone are not. A lone "+", "≤" or "∅" carries meaning.
    /// A string of brackets, as the parenthesis expression "())()(", is read too.
    private static func containsReadableScalar(_ token: String) -> Bool {
        if token.count >= 2, token.allSatisfy({ "()[]{}".contains($0) }) { return true }
        // An operator of two signs, as "--" or "++", is read too.
        if token.count >= 2, token.allSatisfy({ "+-=<>!&|".contains($0) }) { return true }
        return token.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.generalCategory == .mathSymbol
                || "∅∞&%#√∑∏∫∂∇∀∃⋯/@*\\".unicodeScalars.contains(scalar)
        }
    }

    private static func isHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 90 else { return false }
        if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
            return true
        }
        let pattern = #"^(chapter|section|part|book)\s+([0-9ivxlcdm]+|[a-z])[:\.\-\s]?.*$"#
        return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func headingTitle(from line: String) -> String {
        line
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RSVPWord: Equatable, Sendable {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var pivotIndex: Int {
        let count = raw.count
        switch count {
        case 0...1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }

    public var splitForDisplay: (prefix: String, pivot: String, suffix: String) {
        guard !raw.isEmpty else { return ("", "", "") }
        let safePivot = min(pivotIndex, raw.count - 1)
        let pivot = raw.index(raw.startIndex, offsetBy: safePivot)
        let afterPivot = raw.index(after: pivot)
        return (
            String(raw[..<pivot]),
            String(raw[pivot]),
            String(raw[afterPivot...])
        )
    }

    /// Words longer than six letters stay on screen 10% longer per extra letter, up to 2.2×.
    public var lengthDelayMultiplier: Double {
        let letters = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return 1 + min(1.2, Double(max(0, letters - 6)) * 0.1)
    }

    /// Ends with a full stop, question mark or exclamation mark, ignoring closing quotes and brackets.
    public var endsSentence: Bool {
        let ending = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
        return ending.hasSuffix(".") || ending.hasSuffix("!") || ending.hasSuffix("?") || ending.hasSuffix("…")
    }

    /// Breaks in the text get a pause sized to the break: longest after a sentence, then after
    /// a colon or dash, then a semicolon, then a comma.
    public var punctuationDelayMultiplier: Double {
        let ending = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
        if endsSentence {
            return 2.6
        }
        if ending.hasSuffix(":") || raw.contains("—") || ending.hasSuffix("–") || raw == "-" {
            return 2.1
        }
        if ending.hasSuffix(";") {
            return 1.7
        }
        if ending.hasSuffix(",") {
            return 1.4
        }
        return 1
    }
}

public struct TextToken: Equatable, Sendable {
    public let text: String
    public let range: NSRange
}

public struct TokenizedText: Equatable, Sendable {
    public let text: String
    public let tokens: [TextToken]
}
