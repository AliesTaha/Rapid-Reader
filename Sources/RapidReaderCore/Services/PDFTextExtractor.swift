import Foundation
import PDFKit

public enum PDFTextExtractor {
    public static func importPDF(at url: URL) throws -> ImportedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentImportError.unreadableFile(url.lastPathComponent)
        }
        var figures: [PDFLayoutAnalyzer.PageFigure] = []
        let pages = cleanedPages((0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "" }
            let layout = PDFLayoutAnalyzer.layout(of: page, firstFigureNumber: figures.count)
            figures += layout.figures
            return layout.lines.joined(separator: "\n")
        })
        var chapters: [(page: Int, title: String)] = []
        func visit(_ outline: PDFOutline) {
            if let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination, let page = destination.page,
               let title = outline.label, !title.isEmpty {
                let index = document.index(for: page)
                // Cross-reference labels such as "[eq:ipw-estimand]" are no part of a title.
                let title = title.replacingOccurrences(of: #"\[[a-z]+:[^\]]*\]"#, with: "", options: .regularExpression)
                if index != NSNotFound { chapters.append((index, title)) }
            }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index) { visit(child) }
            }
        }
        if let outline = document.outlineRoot { visit(outline) }
        // Outline order is kept among entries on one page; each finds its own heading line below.
        chapters = chapters.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        if let first = chapters.first, first.page > 0 { chapters.insert((0, "Opening"), at: 0) }

        let mark = PDFLayoutAnalyzer.headingPrint
        var sections: [BookSection]
        if chapters.isEmpty {
            sections = pages.enumerated().map { BookSection(title: "Page \($0.offset + 1)", text: $0.element.replacingOccurrences(of: mark, with: "")) }
        } else {
            // A section starts at its heading, not at the top of its page: the outline points at the
            // page, and an anchor set just above a heading can even fall at the foot of the page before.
            var pageLines = pages.map { $0.components(separatedBy: "\n") }
            // Headings the outline leaves out, as "Sum queries" under "9.1 Static array queries", are
            // marked by the layout; they start sections of their own.
            var headings: [(page: Int, line: Int)] = []
            for page in pageLines.indices {
                // A chapter's number set large over its title, as "Chapter 12", is not read; the
                // section's title says where it starts.
                pageLines[page].removeAll { $0.hasPrefix(mark) && $0.dropFirst(mark.count).range(of: #"^(Chapter|Part)\s+([0-9]+|[IVXL]+)$"#, options: .regularExpression) != nil }
                for line in pageLines[page].indices where pageLines[page][line].contains(mark) {
                    if pageLines[page][line].hasPrefix(mark) { headings.append((page, line)) }
                    pageLines[page][line] = pageLines[page][line].replacingOccurrences(of: mark, with: "")
                }
            }
            var starts: [(page: Int, line: Int)] = []
            for (number, chapter) in chapters.enumerated() {
                let previous = starts.last ?? (0, 0)
                let found = headingLine(chapter.title, in: pageLines, near: chapter.page)
                // A title cut short where it held mathematics, as "Proof of ", takes the heading's
                // own words: "Proof of Theorem 2".
                if let found, chapter.title.trimmingCharacters(in: .whitespaces).range(of: #"\b(of|for|to|and|with|on|in)$|:$"#, options: .regularExpression) != nil {
                    chapters[number].title = pageLines[found.page][found.line].replacingOccurrences(of: #"^[A-Z]?\d*(\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
                }
                starts.append(found.map { $0 >= previous ? $0 : (chapter.page, 0) } ?? (chapter.page, 0))
                if starts[starts.count - 1] < previous { starts[starts.count - 1] = previous }
            }
            func text(from start: (page: Int, line: Int), to end: (page: Int, line: Int)) -> String {
                guard start < end else { return "" }
                return (start.page...min(end.page, pages.count - 1)).map { page in
                    let lines = pageLines[page]
                    let first = page == start.page ? start.line : 0
                    let last = page == end.page ? end.line : lines.count
                    return first < last ? lines[first..<last].joined(separator: "\n") : ""
                }.joined(separator: "\n\n")
            }
            // The section's title shows above its text, so the heading it starts with, as "3.1
            // Sorting theory" or "Chapter 3" over "Sorting", is not read again.
            func letters(_ value: String) -> String { value.lowercased().filter(\.isLetter) }
            func heading(_ line: String, of title: String, partly: Bool = false) -> Bool {
                let line = line.hasPrefix(PDFLayoutAnalyzer.smallPrint) ? String(line.dropFirst(PDFLayoutAnalyzer.smallPrint.count)) : line
                guard !PDFLayoutAnalyzer.isMarker(line), line.count <= title.count + 16 else { return false }
                // A part's title carries its numeral, as "II Graph algorithms" over "Graph algorithms".
                let own = letters(line), wanted = letters(title), bare = letters(title.replacingOccurrences(of: #"^[IVXL]+\s+"#, with: "", options: .regularExpression))
                // At a section's start, a title over two lines, as "4.5.3 Collider Bias and Why to Not
                // Condition on" + "Descendants of Treatment", is not read either.
                return !wanted.isEmpty && (own == wanted || own == bare || own == "chapter" + wanted || own == "part" + wanted || own == "part" + bare
                    || partly && own.count >= 8 && wanted.count >= own.count + 5 && (wanted.hasPrefix(own) || wanted.hasSuffix(own)))
                    || line.range(of: #"^(Chapter|Part)\s+([0-9]+|[IVXL]+)$"#, options: .regularExpression) != nil
            }
            var entries = chapters.indices.map { (start: starts[$0], title: chapters[$0].title) }
            var added: [(page: Int, line: Int)] = []
            for found in headings {
                let line = pageLines[found.page][found.line].trimmingCharacters(in: .whitespaces)
                // A heading over two lines, as "Unobserved Confounding:" + "Bounds and Sensitivity
                // Analysis", starts once; an outline entry's own heading, as "Static array queries" or
                // "Chapter 9" over it, already starts a section. A contents entry, as "6 Nonparametric
                // Identification 61", or an author's affiliation, as "¹Cornell Tech", is no heading.
                let previous = found.line > 0 ? pageLines[found.page][found.line - 1].trimmingCharacters(in: .whitespaces) : ""
                let wrapped = chapters.contains(where: { !letters($0.title).isEmpty && letters(previous + line) == letters($0.title) })
                guard !wrapped, !entries.contains(where: { $0.start == found }),
                      !chapters.contains(where: { abs($0.page - found.page) <= 1 && heading(line, of: $0.title) }),
                      line.first.map({ $0.isLetter || $0.isNumber && $0.isASCII }) == true,
                      line.range(of: #"^[A-Z]?\d+(\.\d+)*\s.*\s\d+$"#, options: .regularExpression) == nil,
                      let after = entries.lastIndex(where: { $0.start <= found }) else { continue }
                // Its number, as the "A.1" of "A.1 Proof of Equation 6.1", is not read in a title.
                entries.insert((found, line.replacingOccurrences(of: #"^([A-Z]|\d+)(\.\d+)*\.?\s+(?=\p{L})"#, with: "", options: .regularExpression)), at: after + 1)
                added.append(found)
            }
            // Entries whose heading could not be told apart from the one before share its start;
            // their text stays with that section.
            let kept = entries.indices.filter { $0 == 0 || entries[$0].start > entries[$0 - 1].start }
            sections = kept.enumerated().map { position, index in
                let end = position + 1 < kept.count ? entries[kept[position + 1]].start : (pages.count, 0)
                var start = entries[index].start
                for _ in 0..<2 where start.page < pageLines.count && start.line < pageLines[start.page].count
                    && (start.page, start.line) < (end.0, end.1) && heading(pageLines[start.page][start.line], of: entries[index].title, partly: true) {
                    start.line += 1
                }
                return BookSection(title: entries[index].title, text: text(from: start, to: end))
            }
            // A section that opens straight on a subheading, as "Working with numbers" on "Integers",
            // has no text of its own; its title goes before the subheading's.
            var merged: [BookSection] = []
            for (position, section) in sections.enumerated() {
                if let last = merged.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   added.contains(where: { $0 == entries[kept[position]].start }) {
                    merged[merged.count - 1] = BookSection(title: last.title + ": " + section.title, text: section.text)
                } else {
                    merged.append(section)
                }
            }
            sections = merged
        }
        let readable = placingFigures(sections, figures: figures)
        guard !readable.isEmpty else { throw DocumentImportError.emptyDocument(url.lastPathComponent) }
        return ImportedDocument(
            title: TextProcessor.cleanedTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, fallback: url.deletingPathExtension().lastPathComponent),
            author: document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
            sourceName: url.lastPathComponent,
            sourceURL: url.absoluteString,
            format: .pdf,
            sections: readable
        )
    }

    /// Letters PDFKit spaced apart, as in "W i th i n", "cu t" or "I f", go back together when
    /// they spell a word and are not words themselves.
    private static let twoLetterWords: Set<String> = ["is", "of", "to", "in", "or", "as", "by", "at", "on", "so", "be", "an", "we", "it", "if", "no",
                                                       "up", "do", "us", "my", "he", "me", "go", "am", "oh", "ok"]

    static func rejoiningSplitWords(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            var tokens = line.components(separatedBy: " ")
            var start = 0
            while start < tokens.count {
                // The last piece may end the sentence, as in "cu t.".
                func letters(_ token: String) -> String { String(token.prefix { $0.isASCII && $0.isLetter }) }
                func fragment(_ token: String) -> Bool {
                    let core = letters(token)
                    return (1...2).contains(core.count) && token.dropFirst(core.count).allSatisfy { ".,;:!?".contains($0) }
                }
                guard fragment(tokens[start]) else { start += 1; continue }
                var end = start
                while end + 1 < tokens.count, letters(tokens[end]) == tokens[end], fragment(tokens[end + 1]) { end += 1 }
                // The longest run from here that spells a word.
                for last in stride(from: end, to: start, by: -1) {
                    let pieces = tokens[start...last].map(letters)
                    let word = pieces.joined()
                    // Dictionaries take abbreviations such as "cu" for words; few two-letter words are real.
                    let strays = pieces.filter { $0.count == 1 ? !["a", "A", "I"].contains($0) : !twoLetterWords.contains($0.lowercased()) }.count
                    let pronoun = pieces.count == 2 && pieces[0] == "I" && ["f", "t", "n", "s"].contains(pieces[1])
                    if word.count >= 3 || pronoun, strays >= 2 || pronoun, word.range(of: #"^[A-Za-z][a-z]+$"#, options: .regularExpression) != nil,
                       WordSplitter.isWord(word) || pronoun {
                        tokens.replaceSubrange(start...last, with: [word + tokens[last].dropFirst(pieces.last!.count)])
                        break
                    }
                }
                start += 1
            }
            // A space PDFKit set one letter off, as "willc larify" or "veryc lose", moves back to
            // where both words are whole.
            var index = 0
            while index + 1 < tokens.count {
                let first = tokens[index], second = tokens[index + 1]
                let tail = String(second.reversed().prefix { ".,;:!?)”’".contains($0) }.reversed())
                let body = String(second.dropLast(tail.count))
                // Lowercase words only, so names and abbreviations such as "et al." stay as they are.
                func plain(_ token: String) -> Bool { !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isLowercase } }
                func word(_ token: String) -> Bool { token.count == 2 ? twoLetterWords.contains(token) : token.count > 2 && (WordSplitter.isWord(token) || WordSplitter.prefixed(token)) }
                guard plain(first), plain(body), first.count >= 2, body.count >= 2,
                      !word(first) && first.count >= 3 || !word(body) && body.count >= 3 else { index += 1; continue }
                let shifts = [(String(first.dropLast()), String(first.last!) + body), (first + String(body.first!), String(body.dropFirst()))]
                if let (left, right) = shifts.first(where: { word($0.0) && word($0.1) && $0.1.dropFirst().allSatisfy(\.isLowercase) }) {
                    tokens[index] = left
                    tokens[index + 1] = right + tail
                }
                index += 1
            }
            return tokens.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// PDFKit puts a hat before the letter it sits on, often at the end of a line and breaking
    /// the word before it apart, as in "a mod e lˆ" + "𝜇as": the hat goes back on its letter,
    /// the word is rejoined and math letters are spaced from the words beside them.
    static func attachingAccents(_ text: String) -> String {
        var result = ""
        var tokens: [String] = []
        let characters = Array(text)
        var index = 0
        func flush() { result += tokens.joined(separator: " "); tokens = [] }
        var current = ""
        while index < characters.count {
            let character = characters[index]
            if character == "ˆ" {
                // Rejoin the pieces just before the hat that spell a word together.
                var words = current.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                for count in stride(from: min(4, words.count), through: 2, by: -1) {
                    let pieces = Array(words.suffix(count)).filter { !$0.isEmpty }
                    guard pieces.count == count, pieces.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }),
                          pieces.contains(where: { $0.count <= 2 }) else { continue }
                    let word = pieces.joined()
                    if word.count >= 2, WordSplitter.isWord(word.lowercased()) || ["to", "of", "in", "is", "on"].contains(word),
                       !pieces.allSatisfy({ $0.count >= 2 && WordSplitter.isWord($0.lowercased()) }) {
                        words.removeLast(count)
                        words.append(word)
                        break
                    }
                }
                current = words.joined(separator: " ")
                // The hat goes on the next letter, past spaces and a line break.
                var next = index + 1
                while next < characters.count, characters[next] == " " || characters[next] == "\n" { next += 1 }
                // Before a picture's marker the hat is already in the picture.
                let marker = PDFLayoutAnalyzer.markerPrefix
                // A hat sits on a letter of mathematics, never on a word's first letter.
                let mathematical = next < characters.count && characters[next].unicodeScalars.first.map {
                    (0x1D400...0x1D7FF).contains($0.value) || (0x0391...0x03C9).contains($0.value)
                } == true
                if mathematical, String(characters[next..<min(characters.count, next + marker.count)]) != marker {
                    let between = characters[(index + 1)..<next].contains("\n") ? "\n" : " "
                    if current.last.map({ $0 != " " && $0 != "\n" }) == true { current += " " }
                    current += String(characters[next]) + "\u{0302}"
                    if between == "\n" { current = current.replacingOccurrences(of: #" ([^ ]\x{0302})$"#, with: "\n$1", options: .regularExpression) }
                    index = next + 1
                    continue
                }
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        result = current
        _ = flush
        // Math letters glued to words, as in "𝜇as" or "by𝑇".
        // Only real words split off, so "𝑖th" and "pa𝑖" stay as they are.
        func real(_ word: Substring) -> Bool {
            ["to", "by", "of", "on", "in", "at", "is", "as", "or", "an", "be", "we", "if", "so"].contains(word) || word.count >= 3 && WordSplitter.isWord(String(word))
        }
        result = result.replacing(/([\x{1D400}-\x{1D7FF}][\x{0300}-\x{036F}]*)([a-z]{2,})/.matchingSemantics(.unicodeScalar)) { match in
            real(match.output.2) ? "\(match.output.1) \(match.output.2)" : String(match.output.0)
        }
        result = result.replacing(/\b([a-z]{2,})([\x{1D400}-\x{1D7FF}])/.matchingSemantics(.unicodeScalar)) { match in
            real(match.output.1) ? "\(match.output.1) \(match.output.2)" : String(match.output.0)
        }
        return result
    }

    /// The line holding a section's heading on its outline page or the page after, such as
    /// "9.2 Maximum subarray sum" for "Maximum subarray sum", where one is found.
    static func headingLine(_ title: String, in pages: [[String]], near page: Int) -> (page: Int, line: Int)? {
        func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let wanted = letters(title)
        guard wanted.count >= 4 else { return nil }
        let cutShort = title.trimmingCharacters(in: .whitespaces).range(of: #"\b(of|for|to|and|with|on|in)$|:$"#, options: .regularExpression) != nil
        for candidate in [page, page + 1] where pages.indices.contains(candidate) {
            let lines = pages[candidate]
            for (index, line) in lines.enumerated() where !PDFLayoutAnalyzer.isMarker(line) && line.count <= title.count + 24 {
                let have = letters(line)
                // A heading can wrap onto a second line.
                let joined = index + 1 < lines.count ? have + letters(lines[index + 1]) : have
                let numberless = letters(line.replacingOccurrences(of: #"^[A-Z]?\d*(\.\d+)*\.?\s+"#, with: "", options: .regularExpression))
                if cutShort ? numberless.hasPrefix(wanted) && numberless.count > wanted.count : have.hasSuffix(wanted) || have.count >= 8 && wanted.hasPrefix(have.drop { $0.isNumber }) && joined.hasSuffix(wanted) {
                    // A section number PDFKit left on a line of its own, as "3.2.3", starts the heading.
                    if index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).range(of: #"^[A-Z]?\d+(\.\d+)*\.?$"#, options: .regularExpression) != nil {
                        return (candidate, index - 1)
                    }
                    return (candidate, index)
                }
            }
        }
        return nil
    }

    /// Turns figure markers into word positions. Figures with no word after them in their
    /// section, including whole sections without prose, open the next readable section.
    static func placingFigures(_ sections: [BookSection], figures: [PDFLayoutAnalyzer.PageFigure]) -> [BookSection] {
        var readable: [BookSection] = []
        var carried: [SectionFigure] = []
        for section in sections {
            let resolved = PDFLayoutAnalyzer.resolveFigures(in: section.text, figures: figures)
            let wordCount = TextProcessor.tokenize(resolved.text).count
            var placed = carried.map { figure in
                var figure = figure
                figure.wordIndex = 0
                return figure
            }
            // A figure after the last word, as a display ending a proof, closes its own section.
            placed += resolved.figures.map { figure in
                var figure = figure
                figure.wordIndex = min(figure.wordIndex, wordCount)
                return figure
            }
            carried = []
            guard wordCount > 0 else {
                carried = placed
                continue
            }
            readable.append(BookSection(id: section.id, title: section.title, text: resolved.text, wordCount: wordCount, figures: placed))
        }
        if var last = readable.popLast() {
            last.figures += carried.map { figure in
                var figure = figure
                figure.wordIndex = last.wordCount - 1
                return figure
            }
            readable.append(last)
        }
        return readable
    }

    /// Joins words split across lines. "exam-" + "ple" loses its hyphen, but a compound such as
    /// "two-" + "dimensional" keeps it: the hyphen stays unless the joined word is in the dictionary.
    static func dehyphenated(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(\p{L}+)-\n(\p{Ll}[\p{L}ﬀﬁﬂﬃﬄ]*)"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let first = Range(match.range(at: 1), in: result),
                  let second = Range(match.range(at: 2), in: result) else { continue }
            let head = String(result[first]), tail = String(result[second])
            let compound = WordSplitter.isWord(head) && WordSplitter.isWord(tail)
            // A compound the page writes with a hyphen elsewhere, as "pre-order" beside "post-" +
            // "order", keeps it.
            let sibling = compound && text.range(of: #"\p{L}-"# + NSRegularExpression.escapedPattern(for: tail) + #"\b"#, options: .regularExpression) != nil
            let closed = WordSplitter.isWord(head + tail) && !sibling
            // A rejoined word can still hide a missing space, as in "nonran-" + "domizedstudies".
            let rejoined = closed || head.count + tail.count < 12 ? head + tail : WordSplitter.split(head + tail)
            // A compound that goes on, as "English-" + "to-German", keeps its words together.
            let goesOn = result[whole.upperBound...].first.map { !$0.isWhitespace } ?? false
            result.replaceSubrange(whole, with: closed || !compound ? rejoined : head + "-" + tail + (goesOn ? "" : "\n"))
        }
        return result
    }

    static func cleanedPages(_ pages: [String]) -> [String] {
        let mark = PDFLayoutAnalyzer.smallPrint
        let marked = pages.map { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != mark } }
        // Running headers and page numbers are matched without the small-print mark.
        func plain(_ line: String) -> String { line.hasPrefix(mark) ? String(line.dropFirst(mark.count)) : line }
        let lines = marked.map { $0.map(plain) }
        // Figure markers never count as running headers or page numbers.
        func edges(_ page: [String]) -> (first: Int?, last: Int?) {
            (page.firstIndex { !PDFLayoutAnalyzer.isMarker($0) }, page.lastIndex { !PDFLayoutAnalyzer.isMarker($0) })
        }
        // A chapter's running header carries its page number, as in "2 Potential Outcomes 14",
        // so headers are also counted with their numbers set aside.
        func numbered(_ value: String) -> String? {
            value.range(of: #"^\d+\s+\D.*|.*\D\s+\d+$"#, options: .regularExpression) != nil
                ? value.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression) : nil
        }
        var counts: [String: Int] = [:]
        var numberedCounts: [String: Int] = [:]
        for page in lines {
            let (first, last) = edges(page)
            for edge in Set([first, last].compactMap { $0 }.map { page[$0] }) where edge.count <= 100 {
                counts[edge, default: 0] += 1
                if let key = numbered(edge) { numberedCounts[key, default: 0] += 1 }
            }
        }
        let threshold = max(3, Int(ceil(Double(pages.count) * 0.7)))
        // Printed page numbers trail the page index by a fixed amount; once that is known, a page's
        // own number goes wherever reading order put it, as after margin notes.
        var offsets: [Int: Int] = [:]
        for (index, page) in lines.enumerated() {
            for line in Set(page) where line.count <= 4 {
                if let number = Int(line), number > 0 { offsets[index - number, default: 0] += 1 }
            }
        }
        let ranked = offsets.sorted { $0.value > $1.value }
        let offset = ranked.first.flatMap { best in best.value >= 5 && best.value >= (ranked.dropFirst().first?.value ?? 0) * 3 ? best.key : nil }
        var kept: [[String]] = marked.enumerated().map { index, page in
            var cleaned = page
            if let offset {
                // So does a running header that carries it, as "5 Randomized Experiments 50" or "A Proofs 87".
                let number = String(index - offset)
                cleaned.removeAll { line in
                    let line = plain(line)
                    guard line != number else { return true }
                    let title = #"(\d{1,2}|[A-Z])\s+\p{Lu}[^.!?:]*"#
                    return line.count <= 80 && (line.hasSuffix(" " + number) && line.range(of: "^" + title + #"\s+\d+$"#, options: .regularExpression) != nil
                        || line.hasPrefix(number + " ") && line.range(of: #"^\d+\s+"# + title + "$", options: .regularExpression) != nil)
                }
            }
            func isMargin(_ value: String) -> Bool {
                counts[value, default: 0] >= threshold || numbered(value).map { numberedCounts[$0, default: 0] >= 3 } == true
                    || value.range(of: #"^(?:Page\s+)?\d+(?:\s+(?:of|/)\s*\d+)?$|^[ivxlc]{1,7}$"#, options: .regularExpression) != nil
            }
            // A heading set large, as "Chapter 12" over a chapter's title, is no running header.
            let heading = PDFLayoutAnalyzer.headingPrint
            let (first, last) = edges(cleaned)
            if let last, !cleaned[last].hasPrefix(heading), isMargin(plain(cleaned[last])) { cleaned.remove(at: last) }
            if let first, first != last, !cleaned[first].hasPrefix(heading), isMargin(plain(cleaned[first])) { cleaned.remove(at: first) }
            // Margin notes and side columns can put a running header anywhere in reading order.
            cleaned.removeAll { !$0.hasPrefix(heading) && numbered(plain($0)).map { numberedCounts[$0, default: 0] >= 3 } == true }
            return cleaned
        }
        droppingMarginContents(&kept)
        kept = kept.map(tidyingListings)
        kept = kept.map(raisingFootnoteMarks)
        movingNotes(&kept)
        keepingNotesInSection(&kept)
        movingPageTopCaptions(&kept)
        return kept.map { page in
            // The last item of a list ends where a sentence follows it, as in "…whose
            // highest point is x" + "For example, …".
            var page = page.map(plain)
            var listed = false
            for index in page.indices {
                let line = page[index]
                if line.hasPrefix("• ") { listed = true; continue }
                guard listed, index > 0 else { continue }
                // A list that ended with its own stop, or a heading after it, closes it.
                if line.hasPrefix(PDFLayoutAnalyzer.headingPrint) || page[index - 1].range(of: #"[.!?]["”’)]?$"#, options: .regularExpression) != nil {
                    listed = false
                    continue
                }
                // An item can go on into a display, as "…the definition of δₙ give" + a formula.
                if PDFLayoutAnalyzer.isMarker(line.trimmingCharacters(in: .whitespaces)) { continue }
                if line.first?.isUppercase == true {
                    // An item that wraps, as a book's title over "Contest Training Manual", goes on
                    // after a capitalised word or a small word such as "the" or "to".
                    if page[index - 1].range(of: #"[\p{L}\p{N})\]}’”⁰¹²³⁴⁵⁶⁷⁸⁹]$"#, options: .regularExpression) != nil,
                       page[index - 1].range(of: #"\b(and|or|the|a|an|to|of|in|on|for|from|with|by|at)$|\b\p{Lu}\p{Ll}+$"#, options: .regularExpression) == nil,
                       !PDFLayoutAnalyzer.isMarker(page[index - 1].trimmingCharacters(in: .whitespaces)) {
                        page[index - 1] += "."
                    }
                    listed = false
                }
            }
            // Ligature glyphs, as in "Eﬃciency", are spelled out.
            let joined = page.joined(separator: "\n")
                .replacingOccurrences(of: "\u{00ad}\n", with: "")
                .replacingOccurrences(of: "\u{00ad}", with: "")
                // Punctuation PDFKit set apart after a subscript, as in "dimension dk , and", joins
                // the word before it; on its own it would not be read.
                .replacingOccurrences(of: #"(?<=[\p{L}\p{N})\]}′])[ \t]+([.,;:!?])(?=\s|$)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"(\#(PDFLayoutAnalyzer.markerPrefix)\d+)([.,;:!?])"#, with: "$1 $2", options: .regularExpression)
                // A label glued to its number, as "Figure3.5:Directed", is spaced.
                .replacingOccurrences(of: #"\b(Assumption|Figure|Table|Definition|Theorem|Section|Chapter|Equation|Proposition|Lemma|Corollary|Example|Listing)(\d+(?:\.\d+)*)(:?)(?=\p{Lu})"#, with: "$1 $2$3 ", options: .regularExpression)
                .replacingOccurrences(of: #"\b(Assumption|Figure|Table|Definition|Theorem|Section|Chapter|Equation|Proposition|Lemma|Corollary|Example|Listing)(\d)"#, with: "$1 $2", options: .regularExpression)
                // A title after a number, as "Assumption 2.1(Ignorability", has its space back.
                .replacingOccurrences(of: #"(\d)\((\p{Lu}\p{Ll}{2,})"#, with: "$1 ($2", options: .regularExpression)
                // Items of a list run on into each other once their bullets are not read, as "…to any
                // leaf maxLength(x): …"; an item without its own stop ends at the next bullet.
                .replacingOccurrences(of: #"(?m)(?<!\#(PDFLayoutAnalyzer.markerPrefix)\d{1,5})(?<!\band|\bor)(?<=[\p{L}\p{N}’”⁰¹²³⁴⁵⁶⁷⁸⁹]|[\p{L}\p{N}][)\]}]|^•\s[()\[\]{}]{2,16})\n(?=•\s)"#, with: ";\n", options: .regularExpression)
                // An overbar PDFKit set apart, as in "complement¯ A" or "A ∩¯ B", goes on the name of
                // one letter after it, "Ā"; with no letter after, as in "E¯ [", on the one before.
                .replacingOccurrences(of: #"(?<=[\p{L}\p{N}∩∪])¯\s?(?!\#(PDFLayoutAnalyzer.markerPrefix))([\x{0370}-\x{03FF}]|\p{L}(?![\p{L}(]))"#, with: " $1\u{0304}", options: .regularExpression)
                .replacingOccurrences(of: #"¯\s?(?!\#(PDFLayoutAnalyzer.markerPrefix))([\x{0370}-\x{03FF}]|\p{L}(?![\p{L}(]))"#, with: "$1\u{0304}", options: .regularExpression)
                .replacingOccurrences(of: #"(?<!\p{L})(\p{Lu})¯(?=\s|$)"#, with: "$1\u{0304}", options: .regularExpression)
                // A slashed equals sign PDFKit wrote as a combining stroke, "x ̸= y", is "≠".
                .replacingOccurrences(of: #"\s?\x{0338}\s?="#, with: " ≠", options: .regularExpression)
                // A minus or an operator glued to a word, as "length−4", "is−2³¹", "the==" or "are¬",
                // stands apart from it; "x−1" is mathematics and stays.
                .replacingOccurrences(of: #"(?<![\p{L}\p{N}])([a-z]{3,})([−¬]|==|--)(?=\S)"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\p{L}\p{N}])([a-z]{3,})(==|--)(?=\s)"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\p{L}\p{N}])(of|is|to|in|at|by|as|or|be|on)−(?=\S)"#, with: "$1 −", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=[:,])¬"#, with: " ¬", options: .regularExpression)
                // An operator PDFKit set against the term before it, as "AB= C", "k− a" or "10⊕ 12",
                // stands apart from both sides as typeset.
                .replacingOccurrences(of: #"(?<=[\p{L}\p{N})\]}′])([=≤≥≠<>⊕×+−≈≡])(?= )"#, with: " $1", options: .regularExpression)
                // A function's name keeps its argument: "f (n)" is "f(n)".
                .replacingOccurrences(of: #"(?<![\p{L}\p{N}])([fgh]) \("#, with: "$1(", options: .regularExpression)
                // "O(logn)" and "O(mlogm)" read "O(log n)" and "O(m log m)".
                .replacingOccurrences(of: #"(?<![\p{L}])([a-z])loglog([a-z])(?![\p{L}(])"#, with: "$1 log log $2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\p{L}])([a-z])log([a-z])(?![\p{L}(])"#, with: "$1 log $2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\p{L}])([a-z])log(?= [a-z]\b)"#, with: "$1 log", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\p{L}])log([a-z])(?![\p{L}(])"#, with: "log $1", options: .regularExpression)
                // A centred ellipsis, as in "X2 + · · · + Xn", is one sign.
                .replacingOccurrences(of: #"·\s?·\s?·(\s(?=[)\]}]))?"#, with: "⋯", options: .regularExpression)
                // A web address broken after a slash or a dot goes on without a space.
                .replacingOccurrences(of: #"(https?://\S*[/.])\n(?=\w)"#, with: "$1", options: .regularExpression)
                // A range of pages broken after its dash, as "321–" + "322", is one.
                .replacingOccurrences(of: #"(?<=\d)–\s+(?=\d)"#, with: "–", options: .regularExpression)
                // Bars around a term take no space inside, as "| f(X)|"; a sign set apart from its
                // term, as "(x₁,− y₁)", goes on it.
                .replacingOccurrences(of: #"(?<=\s|\()\| ([^\s|]{1,12}\|)"#, with: "|$1", options: .regularExpression)
                .replacingOccurrences(of: #",−\s(?=\p{L})"#, with: ", −", options: .regularExpression)
                .replacingOccurrences(of: "ﬃ", with: "ffi").replacingOccurrences(of: "ﬄ", with: "ffl")
                .replacingOccurrences(of: "ﬀ", with: "ff").replacingOccurrences(of: "ﬁ", with: "fi").replacingOccurrences(of: "ﬂ", with: "fl")
            return TextProcessor.normalizedText(rejoiningSplitWords(dehyphenated(attachingAccents(composingNameAccents(separatingIdentifiers(joined))))))
        }
    }
    /// A name's accent that PDFKit set apart before its letter, as "K˝ onig", "Sta´ nczyk" or
    /// "Dud´ık", goes on that letter: "Kőnig", "Stańczyk", "Dudík".
    static func composingNameAccents(_ text: String) -> String {
        let marks: [Character: String] = ["˝": "\u{30B}", "´": "\u{301}", "`": "\u{300}", "¨": "\u{308}"]
        guard let pattern = try? NSRegularExpression(pattern: #"(?<=\p{L})([˝´`¨]) ?(\p{Ll}|ı)"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let mark = Range(match.range(at: 1), in: result), let letter = Range(match.range(at: 2), in: result),
                  let combining = marks[result[mark].first!] else { continue }
            let base = result[letter] == "ı" ? "i" : String(result[letter])
            result.replaceSubrange(whole, with: (base + combining).precomposedStringWithCanonicalMapping)
        }
        return result
    }

    /// A name with underscores that the PDF glued to the next word, as "warmup_stepstraining",
    /// is split where a name the page uses elsewhere ends.
    static func separatingIdentifiers(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\b[A-Za-z]\w*_\w+"#) else { return text }
        let tokens = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        let names = Set(tokens)
        var result = text
        for token in names {
            guard let name = names.filter({ $0.count < token.count && token.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { continue }
            let rest = String(token.dropFirst(name.count))
            guard rest.count >= 3, WordSplitter.isWord(rest) else { continue }
            result = result.replacingOccurrences(of: #"\b\#(token)\b"#, with: name + " " + rest, options: .regularExpression)
        }
        return result
    }

    /// A reference's label on a line of its own, as "[12]", joins the entry it labels; on a
    /// contents page, page numbers PDFKit listed apart from their titles are not read.
    static func tidyingListings(_ page: [String]) -> [String] {
        let mark = PDFLayoutAnalyzer.smallPrint
        func plain(_ line: String) -> String { line.hasPrefix(mark) ? String(line.dropFirst(mark.count)) : line }
        var lines: [String] = []
        for line in page {
            if let last = lines.last, plain(last).range(of: #"^\[\d{1,3}\]$"#, options: .regularExpression) != nil, !PDFLayoutAnalyzer.isMarker(line) {
                lines[lines.count - 1] = last + " " + plain(line)
            } else {
                lines.append(line)
            }
        }
        let numbered = lines.filter { plain($0).range(of: #"^\d{1,3}$|\s\d{1,3}$|(\s?\.){3,}\s*\d{1,3}$"#, options: .regularExpression) != nil }.count
        guard numbered >= 8, numbered * 10 >= lines.count * 4 else { return lines }
        return lines.filter { plain($0).range(of: #"^\d{1,3}$"#, options: .regularExpression) == nil }
            // Front matter is numbered in roman figures, as "Preface ix".
            .map { $0.replacingOccurrences(of: #"(\s?\.){3,}\s*\d{1,3}$|(?<=\D)\s+\d{1,3}$|(?<=\p{L})\s+[ivxl]{1,6}$"#, with: "", options: .regularExpression) }
    }

    /// A chapter's contents set small in the margin, as "1.1 Simpson’s Paradox 1" + "1.2
    /// Applications of Causal Inference 2" + …, repeats the book's contents; it is not read.
    static func droppingMarginContents(_ pages: inout [[String]]) {
        let mark = PDFLayoutAnalyzer.smallPrint
        for page in pages.indices {
            var index = 0
            while index < pages[page].count {
                guard pages[page][index].hasPrefix(mark) else { index += 1; continue }
                // A page number alone has no letters to tell its size by.
                var end = index
                while end < pages[page].count, pages[page][end].hasPrefix(mark) || pages[page][end].range(of: #"^\s*\d{1,3}$"#, options: .regularExpression) != nil { end += 1 }
                // The contents end at their last page number, before any sentence or caption.
                let all = pages[page][index..<end].map { $0.hasPrefix(mark) ? $0.dropFirst(mark.count) : Substring($0) }
                let stop = all.firstIndex { $0.range(of: #"[.!]$|^(Figure|Table)\s*\d"#, options: .regularExpression) != nil } ?? all.count
                func numbered(_ line: Substring) -> Bool { line.range(of: #"(^|\s|(?<=\)))\d{1,3}$"#, options: .regularExpression) != nil }
                if let last = all[..<stop].lastIndex(where: numbered) {
                    let run = all[...last]
                    // Entries wrap, as "1.2 Applications of Causal Infer-" + "ence 2", so a line that
                    // opens with a section's number counts too.
                    let entries = run.filter { numbered($0) || $0.range(of: #"^(\d{1,2}|[A-Z])\.\d{1,2}\s"#, options: .regularExpression) != nil }.count
                    if run.count >= 3, run.filter(numbered).count >= 2, entries * 2 >= run.count, !run.contains(where: { PDFLayoutAnalyzer.isMarker(String($0)) }) {
                        pages[page].removeSubrange(index...(index + last))
                        continue
                    }
                }
                index = end
            }
        }
    }

    /// A figure or table set at the top of a page, with its caption, comes between the halves of
    /// a sentence that runs on from the page before, as "…translation on the" + "Table 3: …" +
    /// "development set". It is read once that sentence ends.
    static func movingPageTopCaptions(_ pages: inout [[String]]) {
        let mark = PDFLayoutAnalyzer.smallPrint
        func plain(_ line: String) -> String { line.hasPrefix(mark) ? String(line.dropFirst(mark.count)) : line }
        func marker(_ line: String) -> Bool { PDFLayoutAnalyzer.isMarker(plain(line).trimmingCharacters(in: .whitespaces)) }
        func caption(_ line: String) -> Bool { plain(line).range(of: #"^(Figure|Table)\s*\d+(\.\d+)*[a-z]?\s*[:.]"#, options: .regularExpression) != nil }
        func endsSentence(_ line: String) -> Bool { plain(line).range(of: #"[.!?]["”’)]?$"#, options: .regularExpression) != nil }
        for page in pages.indices.dropFirst() {
            guard let previous = pages[page - 1].last(where: { !marker($0) && !$0.hasPrefix(mark) }), !endsSentence(previous),
                  previous.range(of: #"[:;]$"#, options: .regularExpression) == nil else { continue }
            let lines = pages[page]
            // Pictures and their caption, up to the line where the sentence goes on in lowercase.
            var end = 0, sawCaption = false
            while end < lines.count {
                let line = plain(lines[end]).trimmingCharacters(in: .whitespaces)
                if marker(lines[end]) || lines[end].hasPrefix(mark) { end += 1; continue }
                if caption(lines[end]) { sawCaption = true; end += 1; continue }
                // The caption runs on over lines of its own; the body goes on in lowercase after a
                // picture or a caption's full stop.
                guard sawCaption, end > 0, !line.isEmpty else { break }
                if line.first?.isLowercase == true, marker(lines[end - 1]) || endsSentence(lines[end - 1]) { break }
                end += 1
            }
            guard sawCaption, end < lines.count, end <= 12, plain(lines[end]).first?.isLowercase == true,
                  let close = lines.indices.first(where: { $0 >= end && !marker(lines[$0]) && !lines[$0].hasPrefix(mark) && endsSentence(lines[$0]) }) else { continue }
            let block = Array(lines[..<end])
            pages[page].insert(contentsOf: block, at: close + 1)
            pages[page].removeSubrange(0..<end)
        }
    }

    /// A footnote's number that PDFKit set level with the text, as "algorithm1" over a small
    /// note "1The algorithm was …", is raised after a word, never after a name such as "x1":
    /// "algorithm¹" and "¹ The algorithm was …".
    static func raisingFootnoteMarks(_ page: [String]) -> [String] {
        let mark = PDFLayoutAnalyzer.smallPrint
        let raised: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        func up(_ number: String) -> String { String(number.compactMap { raised[$0] }) }
        var numbers: Set<String> = []
        var page = page
        for index in page.indices where page[index].hasPrefix(mark) {
            let line = String(page[index].dropFirst(mark.count))
            // A mark the layout already raised, as "²J. Bentley’s", stands apart from its note.
            if let match = line.firstMatch(of: /^([⁰¹²³⁴⁵⁶⁷⁸⁹]{1,2})(\p{Lu})/) {
                page[index] = mark + match.output.1 + " " + line.dropFirst(match.output.1.count)
                numbers.insert(String(match.output.1.compactMap { mark in raised.first { $0.value == mark }?.key }))
                continue
            }
            guard let match = line.firstMatch(of: /^([0-9]{1,2}) ?(\p{Lu}[\p{L}’'.]*)/) else { continue }
            let number = String(match.output.1)
            numbers.insert(number)
            page[index] = mark + up(number) + " " + line.dropFirst(number.count).drop { $0 == " " }
        }
        guard !numbers.isEmpty else { return page }
        for index in page.indices where !page[index].hasPrefix(mark) {
            for number in numbers {
                guard let pattern = try? NSRegularExpression(pattern: #"([\p{L}’'.-]*\p{Ll})"# + number + #"(?=[.,:;)]?(\s|$))"#) else { continue }
                let line = page[index]
                var result = line
                for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let whole = Range(match.range, in: result), let word = Range(match.range(at: 1), in: result) else { continue }
                    let letters = result[word].filter(\.isLetter)
                    // The word it follows is a real one, as "algorithm", not a name such as "x" or "diag".
                    // A label in brackets, as "(Int1)", keeps its number.
                    let bracketed = word.lowerBound > result.startIndex && result[result.index(before: word.lowerBound)] == "("
                    guard letters.count >= 3, !bracketed, WordSplitter.isWord(String(letters).lowercased()) || result[word].contains("-") else { continue }
                    result.replaceSubrange(whole, with: result[word] + up(number))
                }
                page[index] = result
            }
        }
        return page
    }

    /// A footnote set at the foot of its page comes after any heading lower on the page than its
    /// mark, as "Example" under the sentence marked "Kruskal’s algorithm¹"; it is read before that
    /// heading, in the section of the sentence it belongs to.
    static func keepingNotesInSection(_ pages: inout [[String]]) {
        let small = PDFLayoutAnalyzer.smallPrint, heading = PDFLayoutAnalyzer.headingPrint
        for page in pages.indices {
            var index = 0
            while index < pages[page].count {
                let line = pages[page][index]
                guard line.hasPrefix(small), index == 0 || !pages[page][index - 1].hasPrefix(small),
                      let mark = line.dropFirst(small.count).first, "¹²³⁴⁵⁶⁷⁸⁹".contains(mark) else { index += 1; continue }
                var end = index + 1
                while end < pages[page].count, pages[page][end].hasPrefix(small) { end += 1 }
                // Where the mark is: this page above the note, or the page before.
                var reference: (page: Int, line: Int)?
                for candidate in [page, page - 1] where candidate >= 0 {
                    let upper = candidate == page ? index : pages[candidate].count
                    if let found = (0..<upper).last(where: { !pages[candidate][$0].hasPrefix(small) && pages[candidate][$0].contains(mark) }) { reference = (candidate, found); break }
                }
                guard let reference else { index = end; continue }
                // The first heading after the mark and before the note.
                var target: (page: Int, line: Int)?
                for candidate in reference.page...page where target == nil {
                    let lower = candidate == reference.page ? reference.line + 1 : 0, upper = candidate == page ? index : pages[candidate].count
                    if lower < upper, let found = (lower..<upper).first(where: { pages[candidate][$0].hasPrefix(heading) }) { target = (candidate, found) }
                }
                guard let target else { index = end; continue }
                let run = Array(pages[page][index..<end])
                pages[page].removeSubrange(index..<end)
                pages[target.page].insert(contentsOf: run, at: target.line)
                index = target.page == page ? end : index
            }
        }
    }

    /// A footnote or margin note that reading order put inside a sentence, as "3,7,11,15" +
    /// "¹A classic book…" + "is an arithmetic progression", moves to the end of that sentence,
    /// on its page or the next.
    static func movingNotes(_ pages: inout [[String]]) {
        let mark = PDFLayoutAnalyzer.smallPrint
        func small(_ line: String) -> Bool { line.hasPrefix(mark) }
        func noteStart(_ line: String) -> Bool {
            small(line) && line.dropFirst(mark.count).range(of: #"^\s*(\d{1,2}|[∗†‡§¶*]+|[⁰¹²³⁴⁵⁶⁷⁸⁹]+|\[\d{1,3}\]:)\s?[\p{L}“"(]"#, options: .regularExpression) != nil
        }
        func body(_ line: String) -> Bool { !small(line) && !PDFLayoutAnalyzer.isMarker(line) }
        // A colon introduces what follows, often a picture; the sentence goes on.
        // "(e.g." and "i.e." do not end one.
        func endsSentence(_ line: String) -> Bool {
            line.range(of: #"[.!?]["”’)]?$"#, options: .regularExpression) != nil
                && line.range(of: #"(\b(e\.g|i\.e|cf|vs|etc|al|Eq|Fig|Sec)\.|\bet al\.)$"#, options: .regularExpression) == nil
        }
        // Notes put before a heading stay there.
        var settled: Set<String> = []
        for page in pages.indices {
            var index = 0
            while index < pages[page].count {
                guard small(pages[page][index]), index == 0 || !small(pages[page][index - 1]), !settled.contains(pages[page][index]) else { index += 1; continue }
                let first = pages[page][index...].firstIndex { small($0) && !PDFLayoutAnalyzer.isMarker(String($0.dropFirst(mark.count))) } ?? index
                let numbered = noteStart(pages[page][first])
                var end = index + 1
                while end < pages[page].count, small(pages[page][end]) { end += 1 }
                // A note is words; small pieces of mathematics are not. A margin note without a
                // number, as "Active reading exercise: …", must be largely words.
                let tokens = pages[page][index..<end].flatMap { $0.split(separator: " ") }
                let words = tokens.filter { $0.range(of: #"^\p{L}\p{Ll}{2,}[.,;:]?$"#, options: .regularExpression) != nil }.count
                // Without a number, a run with mathematics cropped inside its lines, as "⟦⟧ be its
                // law, ⟦⟧ its temperature,", is a small line of the body.
                let inline = pages[page][index..<end].contains { $0.replacingOccurrences(of: mark, with: "").range(of: #"\S\s*\#(PDFLayoutAnalyzer.markerPrefix)|\#(PDFLayoutAnalyzer.markerPrefix)\d+\s*\S"#, options: .regularExpression) != nil }
                // A margin figure, marked small by the layout, comes with its caption, which can hold
                // a crop of its own.
                let figure = pages[page][index..<end].contains { PDFLayoutAnalyzer.isMarker(String($0.dropFirst(mark.count))) }
                guard words >= 3, numbered || words >= 5 && (!inline || figure) && words * 5 >= tokens.count * 2, let previous = pages[page][..<index].last(where: body) ?? (page > 0 && !pages[page][..<index].contains(where: body) ? pages[page - 1].last(where: body) : nil),
                      !endsSentence(previous) else { index = end; continue }
                // The first line after the run that ends a sentence of the body.
                var target: (page: Int, line: Int)?
                var position = (page, end)
                while target == nil, position.0 < pages.count, position.0 <= page + 1 {
                    let lines = pages[position.0]
                    // A heading on the way ends the search: the note stays before it, in its own section.
                    let heading = PDFLayoutAnalyzer.headingPrint
                    if let line = lines.indices.first(where: { $0 >= position.1 && (lines[$0].hasPrefix(heading) || body(lines[$0]) && endsSentence(lines[$0])) }) {
                        target = !lines[line].hasPrefix(heading) ? (position.0, line) : line > 0 ? (position.0, line - 1) : (page, pages[page].count - 1)
                        if lines[line].hasPrefix(heading) { settled.insert(pages[page][index]) }
                    }
                    position = (position.0 + 1, 0)
                }
                guard let target else { index = end; continue }
                let run = Array(pages[page][index..<end])
                if target.page == page {
                    pages[page].insert(contentsOf: run, at: target.line + 1)
                    pages[page].removeSubrange(index..<end)
                } else {
                    pages[target.page].insert(contentsOf: run, at: target.line + 1)
                    pages[page].removeSubrange(index..<end)
                }
            }
        }
    }
}
