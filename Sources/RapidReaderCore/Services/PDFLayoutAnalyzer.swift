import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Splits a PDF page into prose and regions that only make sense as pictures:
/// display formulas, code listings, and images or drawings.
///
/// Each region is cropped from the page as a PNG and replaced in the page text by a marker
/// line, so the regular text cleanup runs unchanged and markers can later be turned into
/// word positions with `resolveFigures(in:figures:)`.
enum PDFLayoutAnalyzer {
    static let markerPrefix = "RRFIGUREMARKER"
    /// Starts a line set in small print, such as a footnote or a margin note.
    static let smallPrint = "\u{E000}"
    /// Starts a heading line set larger than the body, such as "Sum queries".
    static let headingPrint = "\u{E001}"

    struct PageFigure {
        var kind: SectionFigure.Kind
        var imageData: Data
        var text: String
    }

    struct PageLayout {
        /// Text lines in reading order, with marker lines where figures belong.
        var lines: [String]
        var figures: [PageFigure]
    }

    private struct Line {
        var text: String
        var bounds: CGRect
        var kind: SectionFigure.Kind?
        var block: Int?
        var small = false
        var heading = false
    }

    private struct Block {
        var kind: SectionFigure.Kind
        var rect: CGRect
        var firstLine: Int?
    }

    static func layout(of page: PDFPage, firstFigureNumber: Int) -> PageLayout {
        let pageBounds = page.bounds(for: .cropBox)
        // Link borders, as the boxes around "Table 3", are not part of the page's ink or pictures.
        page.displaysAnnotations = false
        let pageText = (page.string ?? "") as NSString
        var found: [(selection: PDFSelection, text: String)] = (page.selection(for: pageBounds)?.selectionsByLine() ?? []).compactMap { selection in
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Inline images show up as attachment characters covering the picture.
            guard !text.isEmpty, !text.contains("\u{fffc}") else { return nil }
            return (selection, text)
        }
        found = found.flatMap { splittingAtSizeChange($0, on: page) }
        respaceRunTogetherLines(&found, on: page, bounds: pageBounds)
        let pageInk = InkMap(page: page, bounds: pageBounds)
        if let pageInk { found = visibleLines(found, on: page, ink: pageInk) }
        // Some PDFs list a page's lines from the bottom up; reading goes from the top down.
        let centres = found.map { $0.selection.bounds(for: page) }
        let steps = zip(centres, centres.dropFirst()).filter { min($0.maxX, $1.maxX) > max($0.minX, $1.minX) }
        if steps.filter({ $1.midY > $0.midY + 1 }).count > steps.filter({ $1.midY < $0.midY - 1 }).count * 2 {
            // Rows from the top, each read from the left.
            var rows: [Int] = Array(repeating: 0, count: found.count), top: CGRect?, row = 0
            let downward = found.indices.sorted { centres[$0].midY > centres[$1].midY }
            for index in downward {
                if let current = top, min(current.maxY, centres[index].maxY) - max(current.minY, centres[index].minY) > min(current.height, centres[index].height) * 0.5 {
                    rows[index] = row
                } else {
                    row += 1
                    rows[index] = row
                    top = centres[index]
                }
            }
            found = found.indices.sorted { (rows[$0], centres[$0].minX) < (rows[$1], centres[$1].minX) }.map { found[$0] }
        }
        // A run-in heading, as "Acknowledgements" before "We are grateful to …", can come before
        // the next row in PDFKit's order, with the rest of its own row after that.
        if found.count >= 3 {
            for index in 0..<(found.count - 2) {
                let heading = found[index].selection.bounds(for: page), between = found[index + 1].selection.bounds(for: page)
                let rest = found[index + 2].selection.bounds(for: page)
                let title = found[index].text.split(whereSeparator: \.isWhitespace)
                func prose(_ text: String) -> Bool { text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3 }
                // A run-in heading, as "Acknowledgements" or "Terms I and III", starts with a capital and
                // ends without punctuation.
                if (1...5).contains(title.count), title.first?.first?.isUppercase == true, title.allSatisfy({ $0.allSatisfy { $0.isLetter } }),
                   found[index + 1].text.split(whereSeparator: \.isWhitespace).contains(where: isWord), prose(found[index + 2].text),
                   min(heading.maxY, rest.maxY) - max(heading.minY, rest.minY) > min(heading.height, rest.height) * 0.5,
                   rest.minX >= heading.maxX - 2, rest.minX - heading.maxX < 20, between.maxY < min(heading.minY, rest.minY) + 1 {
                    found.swapAt(index + 1, index + 2)
                }
            }
            // A reference's row can be split, as "[10] Alex Graves." + "arXiv:1308.0850, 2013." +
            // "Generating sequences …" + "arXiv preprint": the rest of the row comes first.
            for index in 0..<(found.count - 2) where found[index].text.range(of: #"^\[\d{1,3}\]"#, options: .regularExpression) != nil {
                let label = found[index].selection.bounds(for: page), below = found[index + 1].selection.bounds(for: page)
                guard below.maxY < label.minY + 1, below.minX >= label.minX else { continue }
                var end = index + 2, right = label.maxX
                while end < found.count {
                    let piece = found[end].selection.bounds(for: page)
                    guard min(label.maxY, piece.maxY) - max(label.minY, piece.minY) > min(label.height, piece.height) * 0.5,
                          piece.minX >= right - 2, piece.minX - right < 20 else { break }
                    right = piece.maxX
                    end += 1
                }
                guard end > index + 2 else { continue }
                let moved = Array(found[(index + 2)..<end])
                found.removeSubrange((index + 2)..<end)
                found.insert(contentsOf: moved, at: index + 1)
            }
        }
        var respacedTokens = found.map { spacedVariables(in: $0.text) }
        if let pageInk {
            let raised = found.map { raisedTokens(in: $0.text, selection: $0.selection, page: page, ink: pageInk) }
            for index in found.indices { respacedTokens[index].merge(raised[index]) { first, _ in first } }
            for index in found.indices { respacedTokens[index].merge(radicals(in: found[index].text, selection: found[index].selection, page: page, ink: pageInk)) { first, _ in first } }
            rejoinRaisedSplits(&found, respacedTokens: &respacedTokens, raised: raised, on: page)
            rewriteStackedPairs(&found, respacedTokens: &respacedTokens, on: page, ink: pageInk)
        }
        var lines: [Line] = found.map { selection, text in
            // Table-of-contents entries end in dot leaders and are prose, whatever else they hold.
            let leaders = text.range(of: #"(\. ?){4,}"#, options: .regularExpression) != nil
            var text = leaders ? text.replacingOccurrences(of: #"\s*(\. ?){4,}\s*"#, with: " ", options: .regularExpression) : text
            // Short leaders before a page number, as in "Backdoor Adjustment . . . 44".
            text = text.replacingOccurrences(of: #"(\s*\.){3,}\s*(\d+)$"#, with: " $2", options: .regularExpression)
            // A row of box characters, as "• ⊓⊏⊐⊓⊏⊐⊓" for a row of tiles, is read.
            let tiles = text.range(of: #"^[•⊓⊔⊏⊐□\s]+$"#, options: .regularExpression) != nil
            let kind: SectionFigure.Kind? = leaders || tiles ? nil : isMonospaced(selection, on: page, text: pageText, line: text) || looksLikeCode(text) ? .code
                : looksLikeMath(text) ? .formula : isDataRow(text) ? .image : nil
            return Line(text: text, bounds: selection.bounds(for: page), kind: kind)
        }
        guard !lines.isEmpty else {
            return PageLayout(lines: pageText.components(separatedBy: .newlines), figures: [])
        }
        // Footnotes and margin notes are set smaller than the body of the page.
        let sizes = found.map { fontSize(of: $0.selection) }
        // The body size is the middle size by amount of text.
        let weighted = sizes.indices.compactMap { index in sizes[index].map { ($0, found[index].text.count) } }.sorted { $0.0 < $1.0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var running = 0
        if let body = weighted.first(where: { running += $0.1; return running * 2 >= total })?.0 {
            for index in lines.indices { lines[index].small = sizes[index].map { $0 < body * 0.93 } ?? false }
            // A heading is a few words set well above the body size, ending without punctuation.
            // A heading over several lines, as a title and its subtitle, is one: only its first line
            // starts it.
            for index in lines.indices where sizes[index].map({ $0 >= body * 1.2 }) == true && lines[index].kind == nil {
                let words = lines[index].text.split(whereSeparator: \.isWhitespace)
                let continued = index > 0 && sizes[index - 1].map { abs($0 - sizes[index]!) < 0.5 } == true
                    && lines[index - 1].bounds.minY - lines[index].bounds.maxY < sizes[index]! * 1.5
                // A name in capitals, as "IOI" or "ICPC", can be a heading too.
                lines[index].heading = !continued && (1...8).contains(words.count) && words.contains(where: { isWord($0) || $0.count >= 2 && $0.allSatisfy(\.isUppercase) })
                    && lines[index].text.range(of: #"[.,;:]$"#, options: .regularExpression) == nil
            }
        }
        // PDFKit can report a sentence's box tall enough to cover the display beside it, as for
        // "and outcome, it can be rewritten as follows:" over Equation 2.10. The sentence is the
        // band of ink at one edge of the box that runs its whole width.
        if let pageInk {
            let usual = lines.map(\.bounds.height).sorted()[lines.count / 2]
            for index in lines.indices where lines[index].kind == nil && lines[index].bounds.height > max(usual * 2.5, 14)
                && lines[index].text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3 {
                if let band = pageInk.edgeTextBand(in: lines[index].bounds, atLeast: usual * 0.6) { lines[index].bounds = band }
            }
        }
        confirmDisplayFormulas(in: &lines)
        confirmCentredDisplays(in: &lines)
        // A page set entirely in a typewriter font is prose, not a listing.
        if lines.filter({ $0.kind == .code }).count * 10 > lines.count * 6 {
            for index in lines.indices where lines[index].kind == .code { lines[index].kind = nil }
        }

        var blocks = textBlocks(in: &lines)
        if page.rotation == 0 {
            // Node names such as 𝑋3 are left in place, so a diagram whose label row spans its
            // arrows keeps its ink; all other text is blanked a full line tall.
            let lineHeight = typicalLineHeight(lines.map(\.bounds))
            // A sentence of short tokens, as ".9, and 𝔼[𝑌 | 𝑇 = 0]=", is text all the same.
            let textRects = lines.filter { line in
                let tokens = line.text.split(whereSeparator: \.isWhitespace)
                return !tokens.allSatisfy { $0.count <= 3 } || tokens.count >= 5 && tokens.contains(where: isWord)
            }
                .map { fullHeight($0.bounds, lineHeight: lineHeight) }
            for region in graphicRegions(on: page, bounds: pageBounds, textRects: textRects, labels: lines.map { fullHeight($0.bounds, lineHeight: lineHeight) }) {
                addGraphic(region, to: &blocks, lines: &lines, pageArea: pageBounds.width * pageBounds.height)
            }
            mergeNeighbours(&blocks, lines: &lines, acrossKinds: true)
            blocks = compacted(blocks, lines: &lines)
        }
        // A shaded box full of statements is a listing, not a picture.
        for index in blocks.indices where blocks[index].kind != .code {
            // Lines PDFKit split around punctuation, such as a lone "," between string arguments, say nothing.
            let members = lines.filter { $0.block == index && $0.text.count > 2 }
            let statements = members.filter { $0.text.range(of: #"[;{}]\s*$|//|^\s*#(include|define)\b|^\s*typedef\b|<<|>>"#, options: .regularExpression) != nil }
            // Mathematics ends lines in braces too, as in "{1, 2}"; it is not a listing.
            let mathy = members.filter { $0.text.unicodeScalars.contains(where: isTypesetMath) }
            if !members.isEmpty, statements.count * 2 >= members.count, mathy.count * 2 < members.count { blocks[index].kind = .code }
        }
        // Evenly spaced digits can pass for a typewriter font; a "listing" with no statement in it,
        // such as "= 1k + 2k + 3k + ... + nk", is a formula.
        for index in blocks.indices where blocks[index].kind == .code {
            let members = lines.filter { $0.block == index && $0.text.count > 2 }
            // Only constructs mathematics never uses count: "AB[i,j] =" or "S = a + ak" are maths.
            let program = members.contains { $0.text.range(of: #"[;{]\s*$|^\s*\}|//|^\s*#|\b(int|long|void|while|return|cout|cin|vector|typedef|struct|auto|bool|char|double)\b|\bfor\s*\(|\bif\s*\(|\w\.\w+\(|<<|>>|\+\+|==|!=|^\s*\d{0,3}\s*(import|from|def|class|print|return)\b|\w\(\)|\[\[|\['"#, options: .regularExpression) != nil }
            if !members.isEmpty, !program { blocks[index].kind = .formula }
        }
        // A block of math letters is a formula even if one of its lines looked like code.
        for index in blocks.indices where blocks[index].kind == .code {
            let members = lines.filter { $0.block == index }
            let mathy = members.filter { $0.text.unicodeScalars.contains { (0x1D400...0x1D7FF).contains($0.value) } }
            if !members.isEmpty, mathy.count * 2 >= members.count { blocks[index].kind = .formula }
        }
        absorbFormulaFragments(into: &blocks, lines: &lines)
        attachLabels(to: &blocks, lines: &lines)
        dissolveInlineBlocks(&blocks, lines: &lines)
        separateColumns(&blocks, lines: &lines)
        splitOutProse(from: &blocks, lines: &lines)
        mergeOverlapping(&blocks, lines: &lines)
        // Numbered pseudocode steps ("3: for j = 1, 2 do") make an algorithm, shown as code.
        for index in blocks.indices {
            let steps = lines.filter { $0.block == index && $0.text.range(of: #"^\s*\d{1,3}:"#, options: .regularExpression) != nil }
            if steps.count >= 3 { blocks[index].kind = .code }
        }
        gatherTables(&blocks, lines: &lines, page: page, bounds: pageBounds)
        gatherFigures(&blocks, lines: &lines, ink: pageInk)
        joinSideBySide(&blocks, lines: &lines)
        attachTableHeaders(&blocks, lines: &lines)
        absorbEnclosedRows(&blocks, lines: &lines)
        settleFigureLabels(&blocks, lines: &lines)
        // A word of the sentence that a formula follows, as the "is" before "|(2·5 − 5·4) + …|", is read.
        for index in lines.indices where lines[index].block.map({ blocks[$0].kind == .formula }) == true
            && lines[index].text.range(of: #"^(is|are|where|and|or|then|so|as|gives|equals)$"#, options: .regularExpression) != nil {
            let block = lines[index].block!
            lines[index].block = nil
            lines[index].kind = nil
            let rest = lines.filter { $0.block == block }.reduce(CGRect.null) { $0.union($1.bounds) }
            if !rest.isNull { blocks[block].rect = rest }
        }
        mergeFormulaColumns(&blocks, lines: &lines)
        gatherOperatorTables(&blocks, lines: &lines)
        // A wordless label lying partly over a drawing, such as a figure's own title, is part of it.
        for index in lines.indices where lines[index].block == nil && lines[index].kind == nil
            && !lines[index].text.split(whereSeparator: \.isWhitespace).contains(where: isWord) && lines[index].text.contains(where: \.isLetter) {
            let bounds = lines[index].bounds
            if let image = blocks.indices.first(where: { blocks[$0].kind == .image && !blocks[$0].rect.isNull
                && blocks[$0].rect.intersection(bounds).width * blocks[$0].rect.intersection(bounds).height >= bounds.width * bounds.height * 0.3 }) {
                lines[index].block = image
            }
        }

        // A caption is read, never part of the picture it describes.
        for index in lines.indices where lines[index].block != nil && blocks.indices.contains(lines[index].block!) && blocks[lines[index].block!].kind == .image
            && lines[index].text.range(of: #"^(Figure|Fig\.|Table)\s*\d+(\.\d+)*[a-z]?\s*[:.]"#, options: .regularExpression) != nil {
            let block = lines[index].block!
            lines[index].block = nil
            let rest = lines.filter { $0.block == block }.reduce(CGRect.null) { $0.union($1.bounds) }
            guard !rest.isNull else { continue }
            let caption = lines[index].bounds
            var rect = blocks[block].rect
            if caption.midY < rest.minY { let top = rect.maxY; rect.origin.y = max(rect.minY, caption.maxY + 1); rect.size.height = top - rect.minY }
            else if caption.midY > rest.maxY { rect.size.height = min(rect.maxY, caption.minY - 1) - rect.minY }
            if rect.height > 4 { blocks[block].rect = rect }
        }
        var figures: [PageFigure] = []
        var markersBefore: [Int: [Int]] = [:]
        var figureRects: [Int: CGRect] = [:]
        let lineHeight = typicalLineHeight(lines.map(\.bounds))
        // PDFKit's line boxes can stop short of a wide equation; the crop follows the ink instead.
        if blocks.contains(where: { $0.kind == .formula || $0.kind == .code }), let ink = InkMap(page: page, bounds: pageBounds) {
            let sentences = lines.filter { $0.block == nil && ($0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3
                || $0.text.range(of: #"[A-Za-z]{5,}"#, options: .regularExpression) != nil) }.map(\.bounds)
            for index in blocks.indices where (blocks[index].kind == .formula || blocks[index].kind == .code) && !blocks[index].rect.isNull {
                // Following the ink must not run along a line of prose.
                let widened = ink.widened(blocks[index].rect)
                if !sentences.contains(where: { widened.contains(CGPoint(x: $0.midX, y: $0.midY)) || ($0.intersects(widened) && !$0.intersects(blocks[index].rect)) }) {
                    blocks[index].rect = widened
                }
            }
        }
        // The sentence that leads into a listing, as "their second elements (second):", is read
        // even when a word of code in it made it look like code: it ends in a colon, holds words
        // and starts left of the listing.
        for index in blocks.indices where blocks[index].kind == .code && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }.sorted { lines[$0].bounds.maxY > lines[$1].bounds.maxY }
            guard members.count >= 3, let top = members.first else { continue }
            let rest = members.dropFirst().map { lines[$0].bounds.minX }.min() ?? 0
            let words = lines[top].text.split(whereSeparator: \.isWhitespace).filter(isWord).count
            if lines[top].text.hasSuffix(":"), words >= 2, lines[top].bounds.minX < rest - 8 {
                lines[top].block = nil
                lines[top].kind = nil
                // The listing keeps its frame's width and starts under the sentence, where it is read.
                let below = members.dropFirst().reduce(CGRect.null) { $0.union(lines[$1].bounds) }
                let rect = blocks[index].rect
                let top = min(rect.maxY, lines[top].bounds.minY - 0.5, below.maxY + 6)
                blocks[index].rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(below.height, top - rect.minY))
                blocks[index].firstLine = members.dropFirst().min()
            }
        }
        // A statement inside a listing's frame, such as "if (n < 2) return false;" that read as
        // mathematics, is part of the listing.
        for index in lines.indices where lines[index].block == nil {
            let bounds = lines[index].bounds
            if let listing = blocks.indices.first(where: { blocks[$0].kind == .code && !blocks[$0].rect.isNull
                && blocks[$0].rect.intersection(bounds).width * blocks[$0].rect.intersection(bounds).height >= bounds.width * bounds.height * 0.85 }) {
                lines[index].block = listing
            }
        }
        for (index, block) in blocks.enumerated() where !block.rect.isNull {
            // A drawing's labels, as the "(2,4)" beside a polygon's corner, are in its picture.
            let labelled = block.kind == .image ? lines.filter { $0.block == index }.reduce(block.rect) { $0.union($1.bounds) } : block.rect
            // Padding stops short of neighbouring text so no half lines show at the edges.
            var crop = labelled.insetBy(dx: -6, dy: -6)
            for line in lines where line.block != index {
                var bounds = fullHeight(line.bounds, lineHeight: lineHeight)
                // A prose line holding inline math can report a box that reaches into the figure;
                // its letters sit within a line height of its centre.
                if line.bounds.intersects(block.rect), line.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3 {
                    let height = min(lineHeight, line.bounds.height)
                    bounds = CGRect(x: line.bounds.minX, y: line.bounds.midY - height / 2, width: line.bounds.width, height: height)
                }
                // A sentence whose centre lies outside the figure is cut off at its full height, even
                // when that height overlaps the figure's own box a little.
                if line.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3, bounds.intersects(crop),
                   min(line.bounds.maxX, crop.maxX) - max(line.bounds.minX, crop.minX) > 8 {
                    if line.bounds.midY > block.rect.maxY {
                        let top = max(min(crop.maxY, bounds.minY - 0.5), block.rect.maxY - 2)
                        crop.size.height = max(0, top - crop.minY)
                        continue
                    }
                    if line.bounds.midY < block.rect.minY {
                        let top = crop.maxY
                        crop.origin.y = min(max(crop.minY, bounds.maxY + 0.5), block.rect.minY + 2)
                        crop.size.height = max(0, top - crop.minY)
                        continue
                    }
                }
                guard bounds.intersects(crop), !bounds.intersects(block.rect) else { continue }
                if line.bounds.midY > block.rect.maxY { crop.size.height = max(0, min(crop.maxY, bounds.minY - 0.5) - crop.minY) }
                if line.bounds.midY < block.rect.minY {
                    let top = crop.maxY
                    crop.origin.y = max(crop.minY, bounds.maxY + 0.5)
                    crop.size.height = max(0, top - crop.minY)
                }
            }
            // A caption under or over the picture is never in it.
            for line in lines where line.block != index && line.bounds.intersects(crop)
                && line.text.range(of: #"^(Figure|Fig\.|Table)\s*\d+(\.\d+)*[a-z]?\s*[:.]"#, options: .regularExpression) != nil {
                if line.bounds.midY < block.rect.midY {
                    let top = crop.maxY
                    crop.origin.y = max(crop.minY, line.bounds.maxY + 0.5)
                    crop.size.height = max(0, top - crop.minY)
                } else {
                    crop.size.height = max(0, min(crop.maxY, line.bounds.minY - 0.5) - crop.minY)
                }
            }
            // Equations and listings made of nothing but stray marks, such as accents PDFKit split
            // off, and crops that came out empty go back to the text rather than show a blank card.
            // Beside an equation or listing, a line with words in it, such as a margin note on the
            // same row, marks where the picture ends.
            let members = lines.filter { $0.block == index }
            if block.kind != .image, !members.isEmpty {
                let span = members.reduce(CGRect.null) { $0.union($1.bounds) }
                for line in lines where line.block != index && line.text.range(of: #"[A-Za-z]{5,}"#, options: .regularExpression) != nil {
                    let overlap = min(line.bounds.maxY, crop.maxY) - max(line.bounds.minY, crop.minY)
                    guard overlap > min(line.bounds.height, span.height) * 0.3 else { continue }
                    if line.bounds.minX >= span.maxX, line.bounds.minX < crop.maxX {
                        crop.size.width = max(span.maxX + 2, line.bounds.minX - 1) - crop.minX
                    } else if line.bounds.maxX <= span.minX, line.bounds.maxX > crop.minX {
                        let right = crop.maxX
                        crop.origin.x = min(span.minX - 2, line.bounds.maxX + 1)
                        crop.size.width = right - crop.minX
                    }
                }
            }
            // A drawing the edge would cut, as the circle around a node "𝑋1" or around the "5" of a
            // tree whose box PDFKit gave by its labels, is taken whole.
            if block.kind == .formula || block.kind == .image, let pageInk {
                let others = lines.filter { $0.block != index && !$0.text.isEmpty }.map(\.bounds)
                let grown = pageInk.grownVertically(pageInk.completingGlyphs(crop, left: nil, right: nil), limit: 6)
                // Only into space no other line uses, so the next display is not half taken.
                let strips = [CGRect(x: grown.minX, y: crop.maxY, width: grown.width, height: max(0, grown.maxY - crop.maxY)),
                              CGRect(x: grown.minX, y: grown.minY, width: grown.width, height: max(0, crop.minY - grown.minY)),
                              CGRect(x: grown.minX, y: grown.minY, width: max(0, crop.minX - grown.minX), height: grown.height),
                              CGRect(x: crop.maxX, y: grown.minY, width: max(0, grown.maxX - crop.maxX), height: grown.height)].filter { $0.width > 0.5 && $0.height > 0.5 }
                if !others.contains(where: { other in strips.contains { $0.intersects(other) } }) { crop = grown }
            }
            // A rule the crop took in at its edge, as the separator of the footnotes under a
            // display, is no part of the formula; it is left out and the crop closes on the rest.
            var erased: [CGRect] = []
            if block.kind == .formula, let pageInk {
                erased = pageInk.separatedRules(in: crop)
                // What lies beyond the rule, as the top of a footnote's mark, is not the formula's either.
                for rule in erased {
                    let top = crop.maxY
                    if rule.midY < crop.midY { crop.origin.y = max(crop.minY, rule.midY) } else { crop.size.height = min(crop.maxY, rule.midY) - crop.minY; continue }
                    crop.size.height = top - crop.minY
                }
                if !erased.isEmpty, let rest = pageInk.inkBounds(in: crop, excluding: erased) { crop = rest.insetBy(dx: -2, dy: -2).intersection(crop) }
            }
            let memberText = lines.filter { $0.block == index }.map(\.text).joined()
            let hollow = block.kind != .image && !memberText.contains(where: { $0.isLetter || $0.isNumber })
            guard !hollow, let image = renderPNG(of: page, rect: crop, pageBounds: pageBounds, erasing: erased),
                  hasInk(image, crop: block.kind == .image ? nil : crop) else {
                for line in lines.indices where lines[line].block == index { lines[line].block = nil }
                continue
            }
            let text = lines.filter { $0.block == index }.map(\.text).joined(separator: "\n")
            // A fragment of the block that PDFKit listed early, as a piece of a display before the
            // heading above it, would put the block before text that is above it on the page.
            var position = block.firstLine ?? placement(of: block.rect, among: lines)
            if block.kind == .formula, position < lines.count {
                let below = lines.indices.first { lines[$0].block == nil && !lines[$0].text.isEmpty && lines[$0].bounds.midY < block.rect.minY
                    && lines[$0].bounds.maxX > block.rect.minX && lines[$0].bounds.minX < block.rect.maxX } ?? lines.count
                let between = (position..<min(below, lines.count)).filter { lines[$0].block == nil && !lines[$0].text.isEmpty }
                if below > position, !between.isEmpty, between.allSatisfy({ lines[$0].bounds.minY > block.rect.midY }) {
                    position = below
                }
            }
            markersBefore[position, default: []].append(firstFigureNumber + figures.count)
            figureRects[firstFigureNumber + figures.count] = block.rect
            figures.append(PageFigure(kind: block.kind, imageData: image, text: text))
        }

        // Inline expressions in sentences are shown as typeset, where PDFKit's positions hold up.
        let inlineInk = pageInk
        let heights = lines.map(\.bounds.height).sorted()
        let usualHeight = heights.isEmpty ? lineHeight : max(heights[heights.count / 2], 8)
        struct Inline { var line: Int; var range: Range<String.Index>; var rect: CGRect; var text: String; var atStart: Bool; var atEnd: Bool
            var pieces: [Int] = []; var claim: (line: Int, range: Range<String.Index>, text: Substring)? }
        var inlines: [Inline] = []
        // Fragment lines a widened crop covers; they are cleared once every crop is placed.
        var absorbed: Set<Int> = []
        // PDFKit can break a sentence's row at a raised or lowered letter, as in "matrices WQ" +
        // "i ∈Rdmodel×dk" + ", WK" + …: the wordless pieces after the sentence on its row, and the
        // start of a sentence they run into, belong to the expression the sentence ends with.
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5 }
        func wordless(_ text: String) -> Bool {
            text.count <= 30 && !text.split(whereSeparator: \.isWhitespace).contains { token in
                let letters = wordLetters(token)
                return letters.count >= 3 && isDictionaryWord(letters)
            }
        }
        struct RowChain { var tail: Range<String.Index>; var rect: CGRect; var text: String; var pieces: [Int]; var claim: (line: Int, range: Range<String.Index>, text: Substring)?; var previousEnd: CGFloat?; var nextStart: CGFloat?; var atEnd: Bool }
        var chains: [Int: RowChain] = [:]
        var claimed: [Int: Range<String.Index>] = [:]
        var taken: Set<Int> = []
        // A sentence's row that PDFKit broke into many pieces around accents and scripts, as in
        // proofs full of inline mathematics, is read left to right: its words stay text and each
        // run of mathematics between them becomes one picture.
        if let ink = inlineInk {
            var visited: Set<Int> = []
            // A row grows from a piece of sentence; pieces join it only when centred on that line.
            func sentencePiece(_ index: Int) -> Bool {
                lines[index].block == nil && lines[index].bounds.height <= lineHeight * 2.5
                    && lines[index].text.split(whereSeparator: \.isWhitespace).filter({ isProseToken(String($0)) }).count >= 2
            }
            for start in lines.indices where !visited.contains(start) && sentencePiece(start) {
                // The row's band is that of its pieces of sentence.
                var seed = lines[start].bounds, inSeed: Set<Int> = [start]
                while let other = lines.indices.first(where: { !inSeed.contains($0) && sentencePiece($0) && !visited.contains($0) && sameRow(lines[$0].bounds, seed)
                    && lines[$0].bounds.midY > seed.minY && lines[$0].bounds.midY < seed.maxY }) {
                    inSeed.insert(other)
                    seed = seed.union(lines[other].bounds)
                }
                var row = [start], queue = [start]
                while let current = queue.popLast() {
                    // Pieces of a row stand side by side; only an accent sits over another piece.
                    for other in lines.indices where !row.contains(other) && !visited.contains(other) && lines[other].block == nil
                        && sameRow(lines[other].bounds, lines[current].bounds)
                        && lines[other].bounds.midY > seed.minY && lines[other].bounds.midY < seed.maxY
                        && max(lines[other].bounds.minX, lines[current].bounds.minX) - min(lines[other].bounds.maxX, lines[current].bounds.maxX) < 12
                        && (min(lines[other].bounds.maxX, lines[current].bounds.maxX) - max(lines[other].bounds.minX, lines[current].bounds.minX)
                                < max(3, min(lines[other].bounds.width, lines[current].bounds.width) * 0.6)
                            || min(lines[other].bounds.width, lines[current].bounds.width) <= 8) {
                        row.append(other)
                        queue.append(other)
                    }
                }
                visited.formUnion(row)
                guard row.count >= 3, let tokens = rowTokens(row.map { (lines[$0].text, found[$0].selection) }, page: page, pageText: pageText) else { continue }
                var words = tokens.map { isProseToken($0.text) }
                // "a" before a word is the article, not a variable, and capitals beside a word, as
                // "DR Remainder", are an acronym.
                for position in tokens.indices.dropLast() where ["a", "A"].contains(tokens[position].text) && words[position + 1] { words[position] = true }
                for position in tokens.indices where !words[position] && tokens[position].text.range(of: #"^[A-Z]{2,5}[.,:;]?$"#, options: .regularExpression) != nil
                    && (position + 1 < tokens.count && words[position + 1] || position > 0 && words[position - 1]) { words[position] = true }
                // A number after an operator, as the "0," of "= 0,", and a name under an accent, as
                // the "In" under a hat, are mathematics.
                let operators = "=<>≤≥≈≲≳+−×·∈∝"
                let numberPattern = #"^\.?\d+([.,]\d+)*[.,;:)\]]*$"#
                let wordHeights = tokens.indices.filter { words[$0] && tokens[$0].text.range(of: numberPattern, options: .regularExpression) == nil }
                    .map { tokens[$0].rect.height }.sorted()
                let wordHeight = wordHeights.isEmpty ? 0 : wordHeights[wordHeights.count / 2]
                for position in tokens.indices where words[position] {
                    let token = tokens[position]
                    let number = token.text.range(of: numberPattern, options: .regularExpression) != nil
                    // Set smaller than the words, as a subscript or a numerator is.
                    if number, token.rect.height < wordHeight * 0.85 { words[position] = false; continue }
                    // or stacked over mathematics, as the numerator of "1/√dk",
                    if number, tokens.indices.contains(where: { !words[$0] && min(tokens[$0].rect.maxX, token.rect.maxX) - max(tokens[$0].rect.minX, token.rect.minX) > 1 }) {
                        words[position] = false
                        continue
                    }
                    // or set right after a name, as the "1" of "p′1".
                    if number, position > 0, !words[position - 1], tokens[position - 1].text.last.map({ $0.isLetter || "′'".contains($0) }) == true {
                        words[position] = false
                        continue
                    }
                    if number, position > 0, !words[position - 1], tokens[position - 1].text.last.map({ operators.contains($0) }) == true { words[position] = false }
                    // A name that is no word, right after a sum or its stacked limits, as the "qiki" of "∑ qiki", is summed.
                    let letters = token.text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                    if !number, position > 0, !words[position - 1], (3...6).contains(letters.count), letters.allSatisfy(\.isLowercase), !isDictionaryWord(letters), !shortWords.contains(letters),
                       (tokens[max(0, position - 3)..<position].contains(where: { $0.text.contains { "∑∏∫".contains($0) } })
                        || tokens.indices.contains(where: { other in other != position - 1 && !words[other] && min(tokens[other].rect.maxX, tokens[position - 1].rect.maxX) - max(tokens[other].rect.minX, tokens[position - 1].rect.minX) > 1 })) {
                        words[position] = false
                        continue
                    }
                    if token.text.count <= 3, tokens.indices.contains(where: { other in
                        !words[other] && tokens[other].text.allSatisfy { "ˆ¯˜′˙^~".contains($0) }
                            && min(tokens[other].rect.maxX, token.rect.maxX) - max(tokens[other].rect.minX, token.rect.minX) > 1 }) { words[position] = false }
                }
                guard words.filter({ $0 }).count >= 2, words.contains(false) else { continue }
                // Runs of mathematics, with a full stop or comma after one kept with it.
                var runs: [[Int]] = [], current: [Int] = []
                for position in tokens.indices {
                    let punctuation = tokens[position].text.allSatisfy { ".,;:".contains($0) }
                    if !words[position] || (punctuation && !current.isEmpty) { current.append(position) } else if !current.isEmpty { runs.append(current); current = [] }
                }
                if !current.isEmpty { runs.append(current) }
                let band = row.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
                let seedLine = lines[start].bounds
                // Only lines of other rows bound the pictures.
                let others = lines.indices.filter { !row.contains($0) && lines[$0].bounds.minX < band.maxX && lines[$0].bounds.maxX > band.minX
                    && abs(lines[$0].bounds.midY - seedLine.midY) > lineHeight * 0.6 }.map { lines[$0].bounds }
                func boundary(_ line: CGRect, above: Bool, centre: CGFloat) -> CGFloat {
                    let half = (line.midY + centre) / 2
                    guard line.height <= usualHeight * 1.3 else { return half }
                    return above ? max(half, line.minY - 0.5) : min(half, line.maxY + 0.5)
                }
                var pictures: [Int: (marker: String, figure: PageFigure)] = [:]
                var complete = true
                for run in runs {
                    var rect = run.reduce(CGRect.null) { $0.union(tokens[$1].rect) }
                    // Pieces of the row inside the run, as a numerator or an accent, are part of it.
                    for member in row where lines[member].bounds.minX >= rect.minX - 1 && lines[member].bounds.maxX <= rect.maxX + 1 { rect = rect.union(lines[member].bounds) }
                    rect = rect.union(CGRect(x: rect.minX, y: seedLine.minY, width: rect.width, height: seedLine.height))
                    let before = run.first.map { $0 > 0 ? tokens[$0 - 1].rect.maxX : nil } ?? nil
                    let after = run.last.map { $0 + 1 < tokens.count ? tokens[$0 + 1].rect.minX : nil } ?? nil
                    rect = ink.grownVertically(rect, limit: lineHeight * 0.3)
                    let ceiling = others.filter { $0.midY > band.midY }.map { boundary($0, above: true, centre: rect.midY) }.min() ?? rect.maxY
                    let floor = others.filter { $0.midY < band.midY }.map { boundary($0, above: false, centre: rect.midY) }.max() ?? rect.minY
                    rect = CGRect(x: rect.minX, y: max(rect.minY, floor), width: rect.width, height: min(rect.maxY, ceiling) - max(rect.minY, floor))
                    guard rect.height >= 4 else { complete = false; break }
                    rect = ink.completingGlyphs(rect, left: before.map { $0 + 0.5 }, right: after.map { $0 - 0.5 })
                    guard let image = renderPNG(of: page, rect: rect.insetBy(dx: -1, dy: -1), pageBounds: pageBounds), hasInk(image) else { complete = false; break }
                    let number = firstFigureNumber + figures.count + pictures.count
                    pictures[run[0]] = ("\(markerPrefix)\(number)", PageFigure(kind: .formula, imageData: image, text: run.map { tokens[$0].text }.joined(separator: " ")))
                }
                guard complete else { continue }
                var text: [String] = []
                for position in tokens.indices {
                    if let picture = pictures[position] { text.append(picture.marker) } else if !runs.contains(where: { $0.contains(position) }) { text.append(tokens[position].text) }
                }
                for start in pictures.keys.sorted() { figures.append(pictures[start]!.figure) }
                let holder = row.min()!
                lines[holder].text = " " + text.joined(separator: " ") + " "
                for member in row where member != holder { absorbed.insert(member) }
                taken.formUnion(row)
            }
        }
        for index in lines.indices where lines[index].block == nil && lines[index].kind == nil && !taken.contains(index)
            && lines[index].text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 1 {
            let own = lines[index].bounds
            // A subscript can start under the last letter of the sentence.
            let beside = lines.indices.filter { $0 != index && lines[$0].block == nil && !taken.contains($0) && sameRow(lines[$0].bounds, own) && lines[$0].bounds.minX > own.midX && lines[$0].bounds.maxX > own.maxX + 3 }
            // TeX sets a fraction after a relation, as in "αν = ν/πb", a little further off.
            let slack: CGFloat = lines[index].text.last.map { "=<>≤≥≈≲≳+−×·∈".contains($0) } == true ? 8 : 4
            var reach = own.maxX, pieces: [Int] = []
            while let next = beside.filter({ !pieces.contains($0) && lines[$0].bounds.minX - reach < slack && wordless(lines[$0].text) })
                .min(by: { lines[$0].bounds.minX < lines[$1].bounds.minX }) {
                pieces.append(next)
                reach = max(reach, lines[next].bounds.maxX)
            }
            // A footnote number after punctuation, as the "10" in "P(X | T = 0).10", is no part of the
            // expression; one after a symbol, as in "253", is an exponent.
            guard let first = pieces.first, !(lines[index].text.last.map({ ".,;:".contains($0) }) == true && lines[first].text.allSatisfy(\.isNumber)) else { continue }
            let expressions = inlineExpressions(in: lines[index].text, selection: found[index].selection, page: page, pageText: pageText)
            guard let tail = expressions.last.flatMap({ $0.atEnd ? (range: $0.range, rect: $0.rect, previousEnd: $0.previousEnd) : nil })
                ?? edgeSymbols(in: lines[index].text, leading: false, selection: found[index].selection, page: page, pageText: pageText)
                    .map({ (range: $0.range, rect: $0.rect, previousEnd: $0.previousEnd) })
            else { continue }
            var chain = RowChain(tail: tail.range, rect: tail.rect, text: String(lines[index].text[tail.range]), pieces: pieces, previousEnd: tail.previousEnd, nextStart: nil, atEnd: true)
            for piece in pieces {
                chain.rect = chain.rect.union(lines[piece].bounds)
                chain.text += " " + lines[piece].text
            }
            if let follower = beside.filter({ !pieces.contains($0) && lines[$0].bounds.minX - reach < slack }).min(by: { lines[$0].bounds.minX < lines[$1].bounds.minX }) {
                chain.atEnd = false
                if let head = edgeSymbols(in: lines[follower].text, leading: true, selection: found[follower].selection, page: page, pageText: pageText) {
                    chain.rect = chain.rect.union(head.rect)
                    chain.text += " " + lines[follower].text[head.range]
                    chain.claim = (follower, head.range, lines[follower].text[head.range])
                    chain.nextStart = head.nextStart
                } else {
                    chain.nextStart = lines[follower].bounds.minX
                }
            }
            chains[index] = chain
            taken.formUnion(pieces)
            if let claim = chain.claim { claimed[claim.line] = claim.range }
        }
        for index in lines.indices where lines[index].block == nil && lines[index].kind == nil && !taken.contains(index) {
            var expressions = inlineExpressions(in: lines[index].text, selection: found[index].selection, page: page, pageText: pageText)
            if let chain = chains[index] {
                if expressions.last?.range == chain.tail { expressions.removeLast() }
                expressions.append((chain.tail, chain.rect, chain.tail.lowerBound == lines[index].text.startIndex, chain.atEnd,
                                    chain.previousEnd, chain.nextStart))
            }
            // The start of a sentence an expression on the line before ran into belongs to that expression.
            for expression in expressions where !(claimed[index].map { $0.overlaps(expression.range) } ?? false) {
                let chain = chains[index].flatMap { $0.tail == expression.range ? $0 : nil }
                // A box taller than one line spans two lines of text.
                guard chain != nil || expression.rect.height <= usualHeight * 1.5 else { continue }
                // Fractions, hats and big brackets reach past the line box; follow their ink, but
                // never into the lines above and below.
                let box = expression.rect
                // Only lines of words bound the crop; pieces such as a numerator PDFKit split off are
                // part of the expression.
                // A line a full row away, such as the next step of an algorithm, bounds it too.
                let neighbours = lines.indices.filter { $0 != index && lines[$0].bounds.minX < box.maxX && lines[$0].bounds.maxX > box.minX
                    && abs(lines[$0].bounds.midY - box.midY) > usualHeight * 0.5
                    && (lines[$0].text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 2
                        || abs(lines[$0].bounds.midY - box.midY) > usualHeight * 1.1 && lines[$0].bounds.height <= usualHeight * 1.3) }.map { lines[$0].bounds }
                // PDFKit's boxes can reach into the next line when a line holds braces, so the
                // boundary with each neighbouring line is halfway between their centres.
                // A neighbour with an ordinary box is trusted up to its edge, so deep subscripts fit.
                func boundary(_ line: CGRect, above: Bool) -> CGFloat {
                    let half = (line.midY + box.midY) / 2
                    guard line.height <= usualHeight * 1.3 else { return half }
                    return above ? max(half, line.minY - 0.5) : min(half, line.maxY + 0.5)
                }
                let ceiling = neighbours.filter { $0.midY > box.midY }.map { boundary($0, above: true) }.min() ?? box.maxY + lineHeight
                let floor = neighbours.filter { $0.midY < box.midY }.map { boundary($0, above: false) }.max() ?? box.minY - lineHeight
                var rect = box
                // An expression that looks unfinished, ending in an open bracket or an operator or
                // running to the edge of its line, goes on in pieces PDFKit split off, such as the
                // raised hats of "‖log(π̂_b/π_b)‖". The crop follows the ink across tight gaps.
                let pieceText = String(lines[index].text[expression.range])
                let open = pieceText.reduce(0) { $0 + ("([{".contains($1) ? 1 : ")]}".contains($1) ? -1 : 0) }
                let operatorEnd = pieceText.last.map { "=<>+−-×·|‖∥≤≥∈⊂∪∩→←(,".contains($0) } ?? false
                let operatorStart = pieceText.first.map { "=<>+−×·|‖∥≤≥∈⊂∪∩→←)".contains($0) } ?? false
                if let ink = inlineInk {
                    let tight = max(1.6, usualHeight * 0.18)
                    // Inside an open bracket, TeX leaves wider gaps around fractions and big operators.
                    if open > 0 || operatorEnd || expression.atEnd { rect = ink.extended(rect, right: true, gap: open > 0 || operatorEnd ? max(tight, 3.2) : tight) }
                    if open < 0 || operatorStart || expression.atStart { rect = ink.extended(rect, right: false, gap: tight) }
                    // Never past the ends of its own line, where the margin column begins, except
                    // over pieces of mathematics PDFKit split off the same row, as the "(m) dΨ,inv(ψ̂"
                    // that goes on from "K(m) = 2(C3(m) + C5".
                    var own = lines[index].bounds
                    let rowPieces = lines.indices.filter { $0 != index && lines[$0].block == nil && !absorbed.contains($0)
                        && sameRow(lines[$0].bounds, lines[index].bounds) && wordless(lines[$0].text) }.map { lines[$0].bounds }
                    var joined: Set<Int> = []
                    while let next = rowPieces.indices.first(where: { !joined.contains($0) && !rowPieces[$0].isEmpty
                        && (rowPieces[$0].minX - own.maxX < 3 && rowPieces[$0].maxX > own.maxX || own.minX - rowPieces[$0].maxX < 3 && rowPieces[$0].minX < own.minX) }) {
                        joined.insert(next)
                        own = own.union(rowPieces[next])
                    }
                    if rect.maxX > max(own.maxX + 3, box.maxX) { rect.size.width = max(own.maxX + 3, box.maxX) - rect.minX }
                    if rect.minX < min(own.minX - 3, box.minX) {
                        let right = rect.maxX
                        rect.origin.x = min(own.minX - 3, box.minX)
                        rect.size.width = right - rect.minX
                    }
                    if let next = expression.nextStart, rect.maxX > max(next - 0.5, box.maxX) {
                        rect.size.width = max(next - 0.5, box.maxX) - rect.minX
                    }
                    if let previous = expression.previousEnd, rect.minX < min(previous + 0.5, box.minX) {
                        let right = rect.maxX
                        rect.origin.x = min(previous + 0.5, box.minX)
                        rect.size.width = right - rect.minX
                    }
                }
                // Following the ink must never run into words: if the extension reaches text with
                // real words in it, the crop keeps PDFKit's box.
                if rect != box {
                    let added = rect.width > box.width ? [CGRect(x: rect.minX, y: rect.minY, width: max(0, box.minX - rect.minX), height: rect.height),
                                                          CGRect(x: box.maxX, y: rect.minY, width: max(0, rect.maxX - box.maxX), height: rect.height)] : []
                    let reachesWords = lines.indices.contains { other in
                        other != index && !(chain?.pieces.contains(other) ?? false) && (lines[other].text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 2
                            || lines[other].text.range(of: #"[A-Za-z]{5,}"#, options: .regularExpression) != nil)
                            && added.contains { !$0.isEmpty && $0.intersection(lines[other].bounds).width > 3 }
                    }
                    if reachesWords { rect = box }
                }
                if rect != box {
                    // Fragment lines now inside the picture are part of it, not words to read.
                    for other in lines.indices where other != index && lines[other].block == nil && lines[other].text.count <= 40 {
                        let overlap = lines[other].bounds.intersection(rect.insetBy(dx: -1, dy: -2))
                        if !overlap.isNull, overlap.width * overlap.height >= lines[other].bounds.width * lines[other].bounds.height * 0.7 {
                            absorbed.insert(other)
                        }
                    }
                }
                rect = inlineInk?.grownVertically(rect, limit: lineHeight * 0.8) ?? rect
                var bottom = max(rect.minY, floor), top = min(rect.maxY, ceiling)
                // A tall expression, such as a binomial coefficient, reaches past halfway to the next
                // line; where blank space parts it from that line, the crop follows its ink, and takes
                // the big brackets beside it.
                if let ink = inlineInk, rect.maxY > ceiling || rect.minY < floor {
                    let above = neighbours.filter { $0.midY > box.midY }.map(\.midY).min() ?? .infinity
                    let below = neighbours.filter { $0.midY < box.midY }.map(\.midY).max() ?? -.infinity
                    // Ink reaching much further, or holding another line's letters, belongs to that line,
                    // as the "is" under "n− k". Line boxes can be far taller than their letters, so the
                    // letters themselves are checked.
                    let reach = usualHeight * 0.55
                    func onlyOwn(_ slice: CGRect) -> Bool {
                        !lines.indices.contains { other in
                            guard other != index, !(chain?.pieces.contains(other) ?? false), lines[other].bounds.intersects(slice),
                                  found[other].selection.numberOfTextRanges(on: page) == 1 else { return false }
                            let range = found[other].selection.range(at: 0, on: page)
                            return (range.location..<NSMaxRange(range)).contains { character in
                                let glyph = page.characterBounds(at: character)
                                return glyph.width > 0 && glyph.intersection(slice).height > 0.5
                            }
                        }
                    }
                    // For a stacked expression, as a binomial, the middle of the next line's box is a guide
                    // only; its letters are what may not be taken.
                    let stacked = rect.height >= usualHeight * 1.25
                    if rect.maxY > ceiling, rect.maxY < min(stacked ? above : above - usualHeight * 0.25, ceiling + (stacked ? reach : usualHeight * 0.4)), ink.blankRow(above: true, of: rect),
                       onlyOwn(CGRect(x: rect.minX, y: ceiling, width: rect.width, height: rect.maxY - ceiling)) { top = rect.maxY }
                    if rect.minY < floor, rect.minY > max(below + usualHeight * 0.25, floor - usualHeight * 0.4), ink.blankRow(above: false, of: rect),
                       onlyOwn(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: floor - rect.minY)) { bottom = rect.minY }
                    if top > ceiling || bottom < floor {
                        let wide = ink.extended(ink.extended(CGRect(x: rect.minX, y: bottom, width: rect.width, height: top - bottom), right: true, gap: 1.6), right: false, gap: 1.6)
                        var left = max(wide.minX, rect.minX - 4, (expression.previousEnd ?? -.infinity) + 0.5)
                        // PDFKit's box for the word before can run over the space and over the big
                        // bracket set there, as the "(" of a binomial after "is": a narrow glyph just
                        // left of a stacked expression, as tall as the bracket closing it, is that bracket.
                        func extent(_ run: Range<CGFloat>, widest: CGFloat = 3.5) -> (low: CGFloat, high: CGFloat)? {
                            let column = CGRect(x: run.lowerBound, y: bottom, width: run.upperBound - run.lowerBound, height: top - bottom)
                            guard run.upperBound - run.lowerBound <= widest, let high = ink.highestInk(in: column), let low = ink.lowestInk(in: column) else { return nil }
                            return (low, high)
                        }
                        let side = CGRect(x: rect.minX - 5, y: bottom, width: 5.5, height: top - bottom)
                        let closing = ink.glyphColumns(in: CGRect(x: rect.maxX - 6, y: bottom, width: 6, height: top - bottom)).compactMap { extent($0, widest: 6) }
                            .max { $0.high - $0.low < $1.high - $1.low }
                        // It reaches as high and as low as the bracket closing the expression, which holds
                        // two rows between them, as a binomial does.
                        let glyphs = ink.finer(page)?.glyphs(in: CGRect(x: rect.minX + 1, y: bottom, width: max(0, rect.width - 7), height: top - bottom), stacking: false) ?? []
                        let rows = glyphs.contains { upper in glyphs.contains { upper.bottom > $0.top + 0.5 } }
                        if top - bottom >= usualHeight * 1.25, rows, let bracket = ink.glyphColumns(in: side).last(where: { $0.upperBound <= rect.minX + 0.5 }),
                           let opening = extent(bracket), let closing, opening.high - opening.low >= usualHeight * 0.8,
                           abs(opening.high - closing.high) <= 2.5, abs(opening.low - closing.low) <= 2.5 {
                            left = min(left, bracket.lowerBound - 0.5)
                        }
                        let right = min(wide.maxX, rect.maxX + 4, (expression.nextStart ?? .infinity) - 0.5)
                        if right > left { rect = CGRect(x: min(rect.minX, left), y: rect.minY, width: max(rect.maxX, right) - min(rect.minX, left), height: rect.height) }
                    }
                }
                // Nor into a figure drawn just above or below.
                for figure in blocks where !figure.rect.isNull && figure.rect.minX < rect.maxX && figure.rect.maxX > rect.minX && !figure.rect.contains(box) {
                    if figure.rect.midY < box.midY { bottom = max(bottom, min(figure.rect.maxY + 0.5, box.minY)) }
                    else if figure.rect.midY > box.midY { top = min(top, max(figure.rect.minY - 0.5, box.maxY)) }
                }
                guard top - bottom >= 4 else { continue }
                rect = CGRect(x: rect.minX, y: bottom, width: rect.width, height: top - bottom)
                // A crop never ends inside a glyph.
                if let ink = inlineInk { rect = ink.completingGlyphs(rect, left: expression.previousEnd, right: expression.nextStart) }
                inlines.append(Inline(line: index, range: expression.range, rect: rect, text: chain?.text ?? String(lines[index].text[expression.range]),
                                      atStart: expression.atStart, atEnd: expression.atEnd, pieces: chain?.pieces ?? [], claim: chain?.claim))
            }
        }
        // An expression that wraps, ending one line and going on at the start of the next line of
        // the same column, becomes one picture with both parts side by side.
        var continuation: [Int: Int] = [:]
        for (position, piece) in inlines.enumerated() where piece.atEnd {
            guard let next = inlines.firstIndex(where: { $0.line == piece.line + 1 && $0.atStart }) else { continue }
            let first = lines[piece.line].bounds, second = lines[piece.line + 1].bounds
            if second.midY < first.midY, abs(second.minX - first.minX) < 40 || second.minX < first.maxX && second.maxX > first.minX {
                continuation[position] = next
            }
        }
        let continuations = Set(continuation.values)
        var claims: [(line: Int, range: Range<String.Index>, text: Substring)] = []
        for position in inlines.indices.reversed() {
            let piece = inlines[position]
            guard !absorbed.contains(piece.line) else { continue }
            if continuations.contains(position) {
                // Shown with the part that starts on the line before.
                lines[piece.line].text.replaceSubrange(piece.range, with: " ")
                continue
            }
            var images = [renderPNG(of: page, rect: piece.rect.insetBy(dx: -1, dy: -1), pageBounds: pageBounds)]
            var text = piece.text
            if let next = continuation[position] {
                images.append(renderPNG(of: page, rect: inlines[next].rect.insetBy(dx: -1, dy: -1), pageBounds: pageBounds))
                text += " " + inlines[next].text
            }
            guard let image = images.count == 1 ? images[0] : joinedSideBySide(images.compactMap { $0 }), hasInk(image) else { continue }
            let marker = " \(markerPrefix)\(firstFigureNumber + figures.count) "
            figures.append(PageFigure(kind: .formula, imageData: image, text: text))
            lines[piece.line].text.replaceSubrange(piece.range, with: marker)
            absorbed.formUnion(piece.pieces)
            if let claim = piece.claim { claims.append(claim) }
        }

        // The start of a sentence an expression ran into is in the picture; ranges further along its
        // line have already been replaced, which leaves this one in place.
        for claim in claims where claim.range.upperBound <= lines[claim.line].text.endIndex
            && lines[claim.line].text[claim.range] == claim.text {
            lines[claim.line].text.replaceSubrange(claim.range, with: " ")
        }
        for index in absorbed { lines[index].text = "" }
        // Mathematics left on a line of its own with no word to read, as "µj/βj/" or "nj,inv"
        // between pieces PDFKit split apart, is shown as typeset rather than read out.
        if let ink = inlineInk {
            for index in lines.indices where lines[index].block == nil && !lines[index].text.contains(markerPrefix) {
                let text = lines[index].text.trimmingCharacters(in: .whitespaces)
                let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
                // Words glued to the mathematics, as in "words,onlyoneofˆ" or "𝑀to𝑌:", are read.
                let glued = text.matches(of: /\p{Ll}{2,}/).contains { !mathWords.contains(String($0.output)) }
                // A lone accent goes onto its letter in the text.
                let accentsOnly = text.allSatisfy { "ˆ¯˜′˙ ".contains($0) }
                guard !tokens.isEmpty, !glued, !accentsOnly, !tokens.contains(where: isProseToken),
                      text.unicodeScalars.contains(where: { isMathSymbol($0) || (0x0391...0x03C9).contains($0.value) || (0x1D400...0x1D7FF).contains($0.value) || "ˆ¯˜′∥".unicodeScalars.contains($0) })
                else { continue }
                let own = lines[index].bounds
                // A line a picture already shows, as the last line of a display repeated by PDFKit, goes.
                if blocks.contains(where: { block in
                    let overlap = block.rect.insetBy(dx: -2, dy: -2).intersection(own)
                    return !overlap.isNull && overlap.width * overlap.height >= own.width * own.height * 0.6 }) {
                    lines[index].text = ""
                    continue
                }
                let others = lines.indices.filter { $0 != index && lines[$0].block == nil && !lines[$0].text.isEmpty && lines[$0].bounds.minX < own.maxX && lines[$0].bounds.maxX > own.minX
                    && abs(lines[$0].bounds.midY - own.midY) > lineHeight * 0.6 }.map { lines[$0].bounds }
                var rect = ink.grownVertically(own, limit: lineHeight * 0.3)
                let ceiling = others.filter { $0.midY > own.midY }.map { max(($0.midY + own.midY) / 2, min($0.minY - 0.5, $0.midY)) }.min() ?? rect.maxY
                let floor = others.filter { $0.midY < own.midY }.map { min(($0.midY + own.midY) / 2, max($0.maxY + 0.5, $0.midY)) }.max() ?? rect.minY
                rect = CGRect(x: rect.minX, y: max(rect.minY, floor), width: rect.width, height: min(rect.maxY, ceiling) - max(rect.minY, floor))
                guard rect.height >= 4 else { continue }
                rect = ink.completingGlyphs(rect, left: nil, right: nil)
                // A fraction right after it, as "ab" over "gcd(a,b)" after "lcm(a,b) =", is part of it.
                func piece(_ other: Int) -> Bool {
                    let box = lines[other].bounds, text = lines[other].text
                    return other != index && lines[other].block == nil && !text.isEmpty && !text.contains(markerPrefix) && text.count <= 12 && !text.contains(" ")
                        && !isDictionaryWord(String(text.filter(\.isLetter)).lowercased())
                        && box.minY < own.maxY + lineHeight * 0.8 && box.maxY > own.minY - lineHeight * 0.8
                }
                var stacked: [Int] = []
                if let near = lines.indices.first(where: { piece($0) && lines[$0].bounds.minX >= rect.maxX - 2 && lines[$0].bounds.minX - rect.maxX < 10 }),
                   let over = lines.indices.first(where: { other in
                       let a = lines[near].bounds, b = lines[other].bounds
                       return other != near && piece(other) && min(a.maxX, b.maxX) - max(a.minX, b.minX) >= min(a.width, b.width) * 0.5
                           && abs(a.midY - b.midY) > min(a.height, b.height) * 0.6
                   }) {
                    stacked = [near, over]
                }
                if !stacked.isEmpty {
                    for other in stacked { rect = rect.union(lines[other].bounds); lines[other].text = "" }
                    rect = ink.completingGlyphs(rect, left: nil, right: nil)
                }
                // Labels inside a small drawing, as the "𝑋1 𝑋2" of two circled nodes, take the
                // drawing: ink beside them that stands taller than the line.
                let wide = ink.widened(rect)
                if wide.width > rect.width + 2 {
                    let sides = [CGRect(x: wide.minX, y: own.midY - lineHeight, width: rect.minX - wide.minX, height: lineHeight * 2),
                                 CGRect(x: rect.maxX, y: own.midY - lineHeight, width: wide.maxX - rect.maxX, height: lineHeight * 2)].filter { $0.width > 0.5 }
                    let tall = sides.allSatisfy { side in
                        guard let high = ink.highestInk(in: side), let low = ink.lowestInk(in: side) else { return true }
                        return high - low > own.height * 1.3
                    }
                    // Nothing else may stand there, on this row or another.
                    let taken = lines.indices.contains { $0 != index && !lines[$0].text.isEmpty && sides.contains(where: lines[$0].bounds.intersects) }
                    if tall, !taken, !others.contains(where: { $0.intersects(wide.insetBy(dx: 0, dy: 1)) }) {
                        let grown = ink.grownVertically(wide, limit: lineHeight * 0.6)
                        rect = others.contains(where: { $0.intersects(grown.insetBy(dx: 0, dy: 1)) }) ? wide : grown
                    }
                }
                guard let image = renderPNG(of: page, rect: rect.insetBy(dx: -1, dy: -1), pageBounds: pageBounds), hasInk(image) else { continue }
                lines[index].text = " \(markerPrefix)\(firstFigureNumber + figures.count) "
                figures.append(PageFigure(kind: .formula, imageData: image, text: text))
            }
        }

        for index in lines.indices where lines[index].block == nil {
            for (token, spaced) in respacedTokens[index].sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) {
                lines[index].text = lines[index].text.replacingOccurrences(of: #"(?<!\S)"# + NSRegularExpression.escapedPattern(for: token) + #"(?!\S)"#,
                                                                           with: NSRegularExpression.escapedTemplate(for: spaced), options: .regularExpression)
            }
        }
        // Notes set small in a side column, as "3 As we’ll see in Chapter 5, …" beside the body,
        // come in reading order between the body's lines; each run of them is read after the body
        // line, from the note's height down, that ends a sentence.
        let bodyLines = lines.indices.filter { lines[$0].block == nil && !lines[$0].small && !lines[$0].text.isEmpty }
        let bodyLeft = bodyLines.map { lines[$0].bounds.minX }.sorted().dropFirst(bodyLines.count / 10).first
        let bodyRight = bodyLines.map { lines[$0].bounds.maxX }.sorted(by: >).dropFirst(bodyLines.count / 10).first
        var deferred: [Int: [Int]] = [:]
        var moved: Set<Int> = []
        if let bodyLeft, let bodyRight, bodyLines.count >= 5 {
            var index = 0
            while index < lines.count {
                func aside(_ line: Line) -> Bool {
                    line.block == nil && line.small && !line.text.isEmpty && (line.bounds.minX >= bodyRight - 4 || line.bounds.maxX <= bodyLeft + 4)
                }
                guard aside(lines[index]) else { index += 1; continue }
                var run = [index]
                var next = index + 1
                while next < lines.count {
                    if aside(lines[next]) { run.append(next) } else if lines[next].block == nil && !lines[next].small && !lines[next].text.isEmpty
                        && !(lines[next].bounds.minX >= bodyRight - 4 || lines[next].bounds.maxX <= bodyLeft + 4) {
                        // A body line between note lines: the note goes on past it only if it is the same note.
                        if let following = (next + 1..<lines.count).first(where: { lines[$0].block == nil && !lines[$0].text.isEmpty }), aside(lines[following]),
                           lines[run.last!].bounds.minY - lines[following].bounds.maxY < 6 { next += 1; continue }
                        break
                    }
                    next += 1
                }
                let top = lines[run[0]].bounds.maxY
                if let target = bodyLines.first(where: { $0 > index && lines[$0].bounds.maxY <= top + 2
                    && lines[$0].text.range(of: #"[.!?]["”’)]?$"#, options: .regularExpression) != nil }), target > run.last! {
                    deferred[target, default: []] += run
                    moved.formUnion(run)
                }
                index = next
            }
        }
        var output: [String] = []
        func emit(_ index: Int) {
            // A full stop PDFKit left on its own, as after the footnote mark in "each GPU⁵" + ".",
            // ends the line before it.
            if lines[index].text.range(of: #"^\s*[.,;:]\s*$"#, options: .regularExpression) != nil, let previous = output.last,
               !previous.trimmingCharacters(in: .whitespaces).isEmpty, !isMarker(previous) {
                output[output.count - 1] = previous.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                    + lines[index].text.trimmingCharacters(in: .whitespaces)
                return
            }
            output.append((lines[index].small && !lines[index].text.isEmpty ? smallPrint : lines[index].heading ? headingPrint : "") + lines[index].text)
        }
        for index in 0...lines.count {
            // A figure in the side column, as a margin figure over its small caption, is marked
            // small like its caption and notes.
            // Pictures before one line come in the page's order, top first.
            output += (markersBefore[index] ?? []).sorted { (figureRects[$0]?.maxY ?? 0) > (figureRects[$1]?.maxY ?? 0) }.map { number in
                let side = figureRects[number].map { rect in bodyRight.map { rect.minX >= $0 - 4 } ?? false } ?? false
                return (side ? smallPrint : "") + "\(markerPrefix)\(number)"
            }
            guard index < lines.count, lines[index].block == nil, !moved.contains(index) else { continue }
            // Text set sideways, as an arXiv stamp in the margin or an axis title, is not read; a
            // figure's picture still shows it.
            if lines[index].text.count >= 8, lines[index].bounds.height > lines[index].bounds.width * 3 { continue }
            emit(index)
            for note in deferred[index] ?? [] { emit(note) }
        }
        return PageLayout(lines: output, figures: figures)
    }

    /// PDFKit can run a line of the body on into a note beside it set smaller, as in
    /// "…is not causation.3 3 As we’ll see in Chapter 5, if we randomly"; such a line is two.
    private static func splittingAtSizeChange(_ line: (selection: PDFSelection, text: String), on page: PDFPage) -> [(selection: PDFSelection, text: String)] {
        guard line.selection.numberOfTextRanges(on: page) == 1, let attributed = line.selection.attributedString, let raw = line.selection.string,
              attributed.string == raw else { return [line] }
        var runs: [(range: NSRange, size: CGFloat)] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
            if let font = font as? NSFont { runs.append((range, font.pointSize)) }
        }
        let text = raw as NSString
        // The first point after a space where the rest of the line is set smaller.
        for (position, run) in runs.enumerated() where position > 0 && run.range.location > 0 {
            let before = runs[..<position].map(\.size).max() ?? 0
            let after = runs[position...].map(\.size).max() ?? 0
            guard after < before * 0.9, text.character(at: run.range.location - 1) == 32 || text.substring(with: run.range).hasPrefix(" ") else { continue }
            let split = run.range.location
            let tail = text.substring(from: split).trimmingCharacters(in: .whitespaces)
            let head = text.substring(to: split).trimmingCharacters(in: .whitespaces)
            guard tail.count >= 8, tail.contains(where: \.isLetter), head.count >= 2 else { return [line] }
            let lineRange = line.selection.range(at: 0, on: page)
            guard lineRange.location != NSNotFound, let first = page.selection(for: NSRange(location: lineRange.location, length: split)),
                  let second = page.selection(for: NSRange(location: lineRange.location + split, length: text.length - split)) else { return [line] }
            return [(first, head), (second, tail)]
        }
        return [line]
    }

    /// The size most of a selection's text is set in.
    private static func fontSize(of selection: PDFSelection) -> CGFloat? {
        guard let attributed = selection.attributedString else { return nil }
        // Letters decide; dot leaders can be set in another size.
        var sizes: [CGFloat: Int] = [:]
        let text = attributed.string as NSString
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
            if let font = font as? NSFont { sizes[font.pointSize, default: 0] += text.substring(with: range).filter(\.isLetter).count }
        }
        return sizes.filter { $0.value > 0 }.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    /// The tokens of a row's pieces in reading order with where each sits, when PDFKit places
    /// every one of them consistently.
    private static func rowTokens(_ pieces: [(text: String, selection: PDFSelection)], page: PDFPage, pageText: NSString) -> [(text: String, rect: CGRect)]? {
        var tokens: [(text: String, rect: CGRect)] = []
        for piece in pieces {
            guard piece.selection.numberOfTextRanges(on: page) == 1, let raw = piece.selection.string,
                  raw.trimmingCharacters(in: .whitespacesAndNewlines) == piece.text else { return nil }
            let lineRange = piece.selection.range(at: 0, on: page)
            guard lineRange.location != NSNotFound else { return nil }
            let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
            let box = piece.selection.bounds(for: page)
            var previous = -CGFloat.infinity
            for token in piece.text.ranges(of: /\S+/) {
                let local = NSRange(token, in: piece.text)
                let range = NSRange(location: lineRange.location + leading + local.location, length: local.length)
                guard NSMaxRange(range) <= pageText.length, pageText.substring(with: range) == String(piece.text[token]),
                      let selection = page.selection(for: range), (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(piece.text[token]) else { return nil }
                var rect = selection.bounds(for: page)
                // A word's box can take in a sign drawn after it without a character, as the "∑"
                // after "disagreement"; the word ends where its letters, as typeset, do.
                if piece.text[token].allSatisfy(\.isLetter), piece.text[token].count >= 2,
                   let typeset = selection.attributedString?.size().width, typeset > 1, rect.width > typeset * 1.15 + 1.5 {
                    rect.size.width = typeset
                }
                // A token placed outside its own piece means PDFKit's positions cannot be trusted.
                // and so does a token placed before the one it follows.
                guard rect.width > 0, rect.minX >= box.minX - 2, rect.maxX <= box.maxX + 2, rect.minX >= previous - 1 else { return nil }
                previous = rect.minX
                tokens.append((String(piece.text[token]), rect))
            }
        }
        return tokens.sorted { $0.rect.minX < $1.rect.minX }
    }

    /// A token of a sentence: a word, possibly bracketed or followed by punctuation.
    private static func isProseToken(_ token: String) -> Bool {
        // An accent PDFKit glued to the word before it, as in "whichˆ", belongs to the mathematics after.
        let token = token.replacingOccurrences(of: #"[ˆ¯˜˙]+$"#, with: "", options: .regularExpression).replacingOccurrences(of: "ﬃ", with: "ffi").replacingOccurrences(of: "ﬄ", with: "ffl").replacingOccurrences(of: "ﬀ", with: "ff")
            .replacingOccurrences(of: "ﬁ", with: "fi").replacingOccurrences(of: "ﬂ", with: "fl")
        let bare = token.replacingOccurrences(of: #"[’']s$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "().,;:!?“”‘’\"'"))
        // Plain numbers, as "layer 5 of 6" or a footnote's "4.", are read, and so are names,
        // abbreviations and a word broken at the end of a line.
        if bare.range(of: #"^\d+([.,]\d+)*$"#, options: .regularExpression) != nil { return true }
        if ["et", "al", "e.g", "i.e", "eg", "ie", "vs", "cf", "Eq", "Eqs", "Fig", "Sec", "resp", "etc"].contains(bare) { return true }
        if token.range(of: #"^[A-Za-z]{2,}-$"#, options: .regularExpression) != nil { return true }
        if bare.range(of: #"^[A-Z][a-z]{2,}$"#, options: .regularExpression) != nil, !mathWords.contains(bare.lowercased()) { return true }
        // An acronym in brackets, as "(CATE)", an assumption's label, as "(A7)" or "(ii)", and a
        // Roman numeral, as "Term III.", are read.
        if token.range(of: #"^\([A-Z]{2,6}s?\)[.,;:]?$|^\((?:[A-Z]?\d+[a-z]?|[ivx]+|[a-z])\)[.,;:]?$|^[IVX]+[.:,]?$"#, options: .regularExpression) != nil { return true }
        // Compounds such as "environment-dependent" are words when their parts are.
        if bare.contains("-") {
            let parts = bare.split(separator: "-")
            return parts.count >= 2 && parts.allSatisfy { $0.count >= 2 && $0.allSatisfy(\.isLetter) && (isDictionaryWord(String($0).lowercased()) || $0.count >= 8) }
        }
        // Contractions such as "haven’t" are words.
        let stem = bare.replacingOccurrences(of: #"['’][a-z]+$"#, with: "", options: .regularExpression)
        guard stem.range(of: #"^[A-Za-z][a-z]*$"#, options: .regularExpression) != nil, !mathWords.contains(stem.lowercased()) else { return false }
        // Two-letter names such as "me" in mathematics are not the pronoun.
        if stem.count <= 2 { return ["is", "of", "to", "in", "or", "as", "by", "at", "on", "so", "be", "an", "we", "it", "if", "no", "up", "do", "us"].contains(stem.lowercased()) }
        // A lowercase run of four or more letters, as "ronment" after "envi-", is part of a word.
        return stem.count >= 4 && stem.allSatisfy(\.isLowercase) || isDictionaryWord(stem.lowercased()) || isDictionaryWord(stem)
    }

    /// Inline expressions in a prose line and where they sit on the page, for lines whose text
    /// is exactly what PDFKit reports and whose letter positions agree with its selections.
    private static func inlineExpressions(in line: String, selection: PDFSelection, page: PDFPage, pageText: NSString) -> [(range: Range<String.Index>, rect: CGRect, atStart: Bool, atEnd: Bool, previousEnd: CGFloat?, nextStart: CGFloat?)] {
        guard selection.numberOfTextRanges(on: page) == 1, let raw = selection.string,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == line, TextProcessor.normalizedText(line) == line else { return [] }
        let lineRange = selection.range(at: 0, on: page)
        guard lineRange.location != NSNotFound, NSMaxRange(lineRange) <= pageText.length else { return [] }
        let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        let lineBounds = selection.bounds(for: page)
        let source = line as NSString
        guard let pattern = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        let tokens = pattern.matches(in: line, range: NSRange(location: 0, length: source.length)).map(\.range)
        let runs = TextProcessor.expressionRuns(in: tokens.map { source.substring(with: $0) })
        var results: [(range: Range<String.Index>, rect: CGRect, atStart: Bool, atEnd: Bool, previousEnd: CGFloat?, nextStart: CGFloat?)] = []
        // Plain words, such as "applied" in "𝒰 → 𝒴 applied" or "(intervention" before "d_A = 2m",
        // stay in the sentence; function names such as "sumq(a,b)" belong to the formula.
        // Names of quantities such as "dk" or "dmodel" are not words.
        func plain(_ index: Int) -> Bool {
            let token = source.substring(with: tokens[index])
            let letters = wordLetters(token)
            return token.range(of: #"^[(\[]?(?:[A-Za-z][a-z]+|[a-z]{2,})[)\],.;:]*$"#, options: .regularExpression) != nil
                && (letters.count >= 8 || letters.count >= 3 && isDictionaryWord(letters) || shortWords.contains(letters.lowercased()))
        }
        // Runs are split where a word with three or more plain words around it breaks the math.
        var pieces: [Range<Int>] = []
        for found in runs {
            let words = (found.lowerBound..<found.upperBound).filter(plain)
            guard words.count >= 2 else { pieces.append(found); continue }
            var start = found.lowerBound
            for word in words {
                if word > start { pieces.append(start..<word) }
                start = word + 1
            }
            if start < found.upperBound { pieces.append(start..<found.upperBound) }
        }
        for found in pieces {
            var run = found
            while run.count > 1, plain(run.upperBound - 1) { run = run.lowerBound..<(run.upperBound - 1) }
            while run.count > 1, plain(run.lowerBound) { run = (run.lowerBound + 1)..<run.upperBound }
            // A name split off the expression's start, as "df" in "df f = 2048" or "dmodel" in
            // "dmodel = 512", belongs to it.
            while run.lowerBound > (pieces.last(where: { $0.upperBound <= found.lowerBound })?.upperBound ?? 0), !plain(run.lowerBound - 1),
                  source.substring(with: tokens[run.lowerBound - 1]).range(of: #"^[A-Za-z]{1,8}$"#, options: .regularExpression) != nil,
                  !isDictionaryWord(source.substring(with: tokens[run.lowerBound - 1])) {
                run = (run.lowerBound - 1)..<run.upperBound
            }
            // An expression that closes a quoted event it did not open, as the "4”) = 1/6" of
            // "P(”the outcome is 4”) = 1/6", starts where that bracket opens; when words lie between,
            // the whole stays text, as it reads well.
            func balance(_ range: Range<Int>) -> Int {
                tokens[range].map { source.substring(with: $0) }.joined().reduce(0) { $0 + ("([{".contains($1) ? 1 : ")]}".contains($1) ? -1 : 0) }
            }
            if balance(run) < 0, tokens[run].map({ source.substring(with: $0) }).joined().range(of: #"[”"]\)"#, options: .regularExpression) != nil {
                var start = run.lowerBound
                while start > max(0, run.lowerBound - 6), balance(start..<run.upperBound) < 0 { start -= 1 }
                guard balance(start..<run.upperBound) >= 0 else { continue }
                if (start..<run.lowerBound).filter(plain).count >= 2 { continue }
                run = start..<run.upperBound
            }
            // An operator written as a word, as the "mod" of "75 mod 17 = 7", joins its operands.
            if run.lowerBound >= 2, source.substring(with: tokens[run.lowerBound - 1]) == "mod",
               source.substring(with: tokens[run.lowerBound - 2]).range(of: #"^[(\[]?[\p{L}\p{N}]{1,3}[)\]]?$"#, options: .regularExpression) != nil {
                run = (run.lowerBound - 2)..<run.upperBound
            }
            let text = tokens[run].map { source.substring(with: $0) }
            // The reader only stops on longer expressions; short ones stay words. A picture is only
            // taken of real mathematics, not of "Positivity/Overlap", "(in Chapter 7)" or "Pearl(2009)".
            // The name "C++" and a command's options, as "(-std=c++11)", are no mathematics.
            let signs = text.joined(separator: " ").replacingOccurrences(of: #"(?i)c\+\+(\d+)?|(?<![\w])\(?-{1,2}[A-Za-z][\w=+.-]*\)?"#, with: "", options: .regularExpression)
            guard run.count > 1 || text.joined().count >= 10,
                  signs.range(of: #"[=<>≤≥≠≈∼∈∉⊂⊆∪∩+−×·→←↔⇒⟹∑∏∫√∞⊥≜|^]|[\x{0391}-\x{03C9}]|[\x{1D400}-\x{1D7FF}]|[\x{2100}-\x{214F}]"#, options: .regularExpression) != nil
            else { continue }
            // An expression holds a word or two at most; a run with more, even glued on as in
            // "0]with … Similarly,", is a sentence and stays text.
            let joined = text.joined(separator: " ")
            let realWords = (try? NSRegularExpression(pattern: #"[A-Za-z]{4,}(?![A-Za-z\d]*[(\[_])"#))?.matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
                .filter { match in
                    let word = (joined as NSString).substring(with: match.range)
                    return !mathWords.contains(word.lowercased()) && (word.count >= 8 || isDictionaryWord(word))
                }.count ?? 0
            guard realWords < 2 else { continue }
            var local = NSRange(location: tokens[run.lowerBound].location, length: NSMaxRange(tokens[run.upperBound - 1]) - tokens[run.lowerBound].location)
            // A word glued on after a closing bracket or a full stop, as in "𝑃(𝑌 |do(𝑡))because" or
            // "𝜇0.Importantly,", or before the expression, as in "Though,𝑌𝑖(𝑡)", stays in the sentence.
            let last = source.substring(with: tokens[run.upperBound - 1]) as NSString
            let glued = last.range(of: #"(?<=[)\]}]|[)\]}\p{N}\p{L}][.,])[A-Z]?[a-z]{2,}[,.;:?!]?$"#, options: .regularExpression)
            if glued.location != NSNotFound, glued.location > 0 { local.length -= glued.length }
            let first = source.substring(with: tokens[run.lowerBound]) as NSString
            let lead = first.range(of: #"^\p{Lu}?[a-z]{2,}[,.;:](?=[^\x00-\x7F])"#, options: .regularExpression)
            if lead.location != NSNotFound, lead.length < local.length {
                local.location += lead.length
                local.length -= lead.length
            }
            let pageRange = NSRange(location: lineRange.location + leading + local.location, length: local.length)
            guard NSMaxRange(pageRange) <= pageText.length, pageText.substring(with: pageRange) == source.substring(with: local),
                  let piece = page.selection(for: pageRange) else { continue }
            let rect = piece.bounds(for: page)
            // The selection must hold the same text and a plausible width for it, inside its line.
            let expected = source.substring(with: local)
            let perCharacter = rect.width / CGFloat(max(expected.count, 1))
            guard (piece.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                  perCharacter > 1.5, perCharacter < 15, rect.minX >= lineBounds.minX - 2, rect.maxX <= lineBounds.maxX + 2,
                  let range = Range(local, in: line) else { continue }
            // Where the neighbouring words of the same line begin and end, so a crop never covers them.
            func edge(of token: Int, start: Bool) -> CGFloat? {
                let range = NSRange(location: lineRange.location + leading + tokens[token].location, length: tokens[token].length)
                guard NSMaxRange(range) <= pageText.length, let selection = page.selection(for: range) else { return nil }
                let bounds = selection.bounds(for: page)
                return bounds.width > 0 ? (start ? bounds.minX : bounds.maxX) : nil
            }
            let nextStart = glued.location != NSNotFound && glued.location > 0 ? rect.maxX
                : run.upperBound < tokens.count ? edge(of: run.upperBound, start: true) : nil
            let previousEnd = run.lowerBound > 0 ? edge(of: run.lowerBound - 1, start: false) : nil
            results.append((range, rect, run.lowerBound == 0, run.upperBound == tokens.count && glued.location == NSNotFound, previousEnd, nextStart))
        }
        return results
    }

    /// PDFKit leaves out the space after an italic variable, as in "nis the sequence length" for
    /// "n is the sequence length" or "htimes" for "h times". A token that is no word but is a
    /// short name glued to a common word gets its space back.
    private static func spacedVariables(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.ranges(of: /\S+/) {
            let text = String(line[token])
            // Dictionaries know "dis"; of one letter and "is", only "his" is a word.
            // The name can end a piece of mathematics, as in "k<ndoes".
            guard let match = text.wholeMatch(of: /(\S*[^\p{L}\s])?(\p{L}{1,3})(is|the|and|in|does|times|are|can)/) else { continue }
            // A capitalised start of two or more letters, as "Ram" in "Ramin", begins a name.
            // Program names such as C++'s "cin" are words of their own.
            if ["cin", "Cin"].contains(text) { continue }
            if match.1 == nil, match.2.count >= 2, match.2.first?.isUppercase == true,
               match.2.count >= 3 || !shortWords.contains(match.2.lowercased()) { continue }
            let glued = String(match.2) + match.3
            guard match.2.count == 1 && match.3 == "is" ? glued.lowercased() != "his" : !isDictionaryWord(glued) else { continue }
            result[text] = "\(match.1 ?? "")\(match.2) \(match.3)"
        }
        return result
    }

    /// Text a figure carries but never draws, such as a hidden "Input-Input Layer5" label, is not
    /// read. A line much taller than its letters can mix such text with a visible heading, so its
    /// words are checked one by one.
    private static func visibleLines(_ found: [(selection: PDFSelection, text: String)], on page: PDFPage, ink: InkMap) -> [(selection: PDFSelection, text: String)] {
        let heights = found.map { $0.selection.bounds(for: page).height }.sorted()
        guard let usual = heights.isEmpty ? nil : heights[heights.count / 2] else { return found }
        // A chart's own titles, such as "Number of people who drowned by falling into a pool", can
        // be left in the PDF unshown, lying across the sentences around the chart in a size of
        // their own; shown lines of text never lie across each other.
        func size(_ selection: PDFSelection) -> CGFloat? {
            guard let attributed = selection.attributedString else { return nil }
            var sizes: [CGFloat: Int] = [:]
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                if let font = font as? NSFont { sizes[font.pointSize, default: 0] += range.length }
            }
            return sizes.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        }
        let sizes = found.map { size($0.selection) }
        var counts: [CGFloat: Int] = [:]
        for size in sizes.compactMap({ $0 }) { counts[(size * 10).rounded() / 10, default: 0] += 1 }
        let body: CGFloat? = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        let words = found.map { $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count }
        let hidden = Set(found.indices.filter { index in
            guard let body, let own = sizes[index], abs(own - body) > body * 0.06, words[index] >= 2,
                  !found[index].text.unicodeScalars.contains(where: isMathSymbol) else { return false }
            let box = found[index].selection.bounds(for: page)
            let crossed = found.indices.filter { other in
                guard other != index, words[other] >= 4, let size = sizes[other], abs(size - body) <= body * 0.06 else { return false }
                let line = found[other].selection.bounds(for: page)
                let overlap = line.intersection(box)
                return line.height <= usual * 1.5 && !overlap.isNull && overlap.height >= min(line.height, box.height) * 0.3 && overlap.width >= box.width * 0.5
            }.map { found[$0].selection.bounds(for: page) }
            // It runs past the sentences it lies across, where nothing is drawn.
            guard let right = crossed.map(\.maxX).max(), let left = crossed.map(\.minX).min() else { return false }
            var past: [CGRect] = []
            if box.maxX - right - 4 >= 6 { past.append(CGRect(x: right + 4, y: box.minY, width: box.maxX - right - 4, height: box.height)) }
            if left - 4 - box.minX >= 6 { past.append(CGRect(x: box.minX, y: box.minY, width: left - 4 - box.minX, height: box.height)) }
            return !past.isEmpty && past.allSatisfy { !ink.inked($0) }
        })
        return found.indices.filter { !hidden.contains($0) }.map { found[$0] }.compactMap { line in
            let bounds = line.selection.bounds(for: page)
            guard ink.inked(bounds.insetBy(dx: -1, dy: -1)) else { return nil }
            // Tall rotated labels in a figure can raise the usual height; body text is at most 12pt.
            guard bounds.height > min(usual, 12) * 1.8, line.selection.numberOfTextRanges(on: page) == 1, let raw = line.selection.string,
                  raw.trimmingCharacters(in: .whitespacesAndNewlines) == line.text else { return line }
            let start = line.selection.range(at: 0, on: page).location + (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
            let shown = line.text.ranges(of: /\S+/).filter { token in
                let local = NSRange(token, in: line.text)
                guard let word = page.selection(for: NSRange(location: start + local.location, length: local.length)) else { return true }
                return ink.inked(word.bounds(for: page).insetBy(dx: -0.5, dy: -0.5))
            }
            guard shown.count < line.text.ranges(of: /\S+/).count else {
                // A label set in its own font beside a heading, as "Input-Input Layer5" after
                // "Attention Visualizations", has no words of its own and is dropped.
                guard let attributed = line.selection.attributedString, attributed.string == raw else { return line }
                // Mathematics in a sentence is set in its own font too, but at the sentence's size.
                var runs: [(text: String, size: CGFloat)] = []
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                    let text = (raw as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { runs.append((text, (font as? NSFont)?.pointSize ?? 0)) }
                }
                let wordy = runs.filter { $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 2 }
                guard runs.count >= 2, let size = wordy.map(\.size).max(), wordy.count < runs.count,
                      runs.allSatisfy({ run in wordy.contains { $0.text == run.text }
                          || !run.text.split(whereSeparator: \.isWhitespace).contains(where: isWord) && run.size > size * 1.25 }) else { return line }
                return (line.selection, wordy.map(\.text).joined(separator: " "))
            }
            guard !shown.isEmpty else { return nil }
            return (line.selection, shown.map { String(line.text[$0]) }.joined(separator: " "))
        }
    }

    /// The letters of a token, without accents PDFKit reports as letters of their own, such as the
    /// "ˆ" of a hat in "modelˆ 𝜇".
    private static func wordLetters<S: StringProtocol>(_ token: S) -> String {
        String(token.filter { character in
            character.isLetter && !character.unicodeScalars.contains { $0.properties.generalCategory == .modifierLetter }
        })
    }

    /// PDFKit gives exponents on the line, so "O(n2)" or "231 − 1" lose their meaning. Characters
    /// whose ink stands clearly above the rest of the token are written as superscripts: "O(n²)",
    /// "2³¹ − 1".
    private static func raisedTokens(in line: String, selection: PDFSelection, page: PDFPage, ink: InkMap) -> [String: String] {
        // A letter can be raised too, as the "k" of "O(nᵏ)" or the "n" of "xⁿ"; such tokens are no words.
        func candidate(_ token: Substring) -> Bool {
            token.contains(where: \.isNumber) || (2...7).contains(token.count) && token.contains(where: \.isLetter)
                && (!isDictionaryWord(String(token.filter(\.isLetter)).lowercased()) || token.filter(\.isLetter).count == 2 && token.filter(\.isLetter).allSatisfy(\.isUppercase))
                && token.filter(\.isLetter).count <= 4
                // A logarithm's base, as the "k" of "logₖ(x)", comes before its argument.
                || token.range(of: #"^\W*(log|sum|min|max)[a-z]\("#, options: .regularExpression) != nil
                // So is a function in an exponent, as the "gcd(k,n)" of "m^gcd(k,n)".
                || token.range(of: #"^\W*[a-z](gcd|lcm|log|min|max)\("#, options: .regularExpression) != nil
        }
        guard line.split(separator: " ").contains(where: candidate) || line.range(of: #"(?<!\S)\p{Lu} \p{Ll}(?!\S)"#, options: .regularExpression) != nil,
              selection.numberOfTextRanges(on: page) == 1, let raw = selection.string,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == line else { return [:] }
        let lineRange = selection.range(at: 0, on: page)
        guard lineRange.location != NSNotFound else { return [:] }
        let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        // A frame's rule just above or below the line would join every column into one.
        var box = ink.withoutRules(selection.bounds(for: page).insetBy(dx: 0, dy: -2))
        let subscripts: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ", "−": "₋", "+": "₊"]
            // Letters Unicode has no small form of, as the "q" of "sum_q" or the "A" of "S_A", are
            // written as an index after an underscore.
            .merging(Dictionary(uniqueKeysWithValues: "bcdfgqwyzABCDEFGHIJKLMNOPQRSTUVWXYZ".map { ($0, Character(UnicodeScalar(0xE100 + Int($0.asciiValue!))!)) })) { first, _ in first }
        let superscripts: [Character: Character] = ["/": "ᐟ", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "−": "⁻", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "k": "ᵏ", "m": "ᵐ", "x": "ˣ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "t": "ᵗ",
            "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ"]
        // The line's baseline is where most of its glyphs end; subscripts and old-style figures
        // such as 7 and 9 reach below it, so the lowest glyph would mislead. A line full of indices,
        // commas and braces, as "B = {x₁, x₂, ¬x₃}", can end more glyphs below its baseline than on
        // it; a level a point or two higher that half as many glyphs end on is the baseline then.
        func level(in box: CGRect) -> CGFloat? {
            let bottoms = ink.glyphColumns(in: box).compactMap { ink.lowestInk(in: CGRect(x: $0.lowerBound, y: box.minY, width: $0.upperBound - $0.lowerBound, height: box.height)) }
            let tally = Dictionary(grouping: bottoms.map { ($0 * 2).rounded() / 2 }, by: { $0 }).mapValues(\.count)
            guard let mode = tally.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), mode.value >= 3 else { return nil }
            let higher = tally.filter { $0.key > mode.key + 0.75 && $0.key <= mode.key + 2.5 && $0.value >= max(3, (mode.value + 1) / 2) }
            return higher.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key ?? mode.key
        }
        guard var baseline = level(in: box) else { return [:] }
        // Glyphs are measured between the lowest a descender reaches and the highest an exponent
        // does, at the size most of the line is set in; the lines above and below can reach into
        // the line's box.
        var sizes: [CGFloat: Int] = [:]
        if let attributed = selection.attributedString {
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                if let size = (font as? NSFont)?.pointSize { sizes[size, default: 0] += range.length }
            }
        }
        guard let size = sizes.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key, size > 0 else { return [:] }
        // PDFKit can stretch the box of a line with exponents over half the next line; the line's
        // own ink is the band the box does not cut.
        if box.height > size * 1.6, let own = ink.rowBands(in: box).filter({ $0.lowerBound > box.minY + 0.5 && $0.upperBound < box.maxY - 0.5 }).max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }),
           own.upperBound - own.lowerBound > size * 0.5 {
            box = CGRect(x: box.minX, y: own.lowerBound - 1, width: box.width, height: own.upperBound - own.lowerBound + 2)
            guard let found = level(in: box) else { return [:] }
            baseline = found
        }
        let low = max(box.minY, baseline - size * 0.3), high = min(box.maxY, baseline + size * 0.95)
        guard high - low > size * 0.6 else { return [:] }
        let band = CGRect(x: box.minX, y: low, width: box.width, height: high - low)
        var result: [String: String] = [:]
        var fine: (FineInk, CGFloat)??
        // A citation such as "[46]:" holds no exponent, whatever its old-style figures look like.
        for whole in line.ranges(of: /\S+/) where line[whole].count >= 2 && candidate(line[whole])
            && line[whole].wholeMatch(of: /\[\d+(,\s*\d+)*\][:,.;]?/) == nil {
          // Glyphs that touch, as the "O(" of "O(n²)", are measured without what comes before the bracket.
          let opened = line[whole].firstIndex(of: "(").map { line.index(after: $0) }.flatMap { $0 < whole.upperBound && line[$0...].first?.isWhitespace == false ? $0..<whole.upperBound : nil }
          // So are those that touch a closing comma or full stop, as the ")," of "O(n²),".
          func trimmed(_ range: Range<String.Index>) -> [Range<String.Index>] {
              var end = range.upperBound
              while end > range.lowerBound, ",.;:".contains(line[line.index(before: end)]) { end = line.index(before: end) }
              return end < range.upperBound && line.distance(from: range.lowerBound, to: end) >= 2 ? [range, range.lowerBound..<end] : [range]
          }
          tokens: for token in trimmed(whole) + (opened.map(trimmed) ?? []) where candidate(line[token]) {
            let text = Array(line[token])
            // Each glyph is a run of inked columns in the token's box; character positions are not
            // trusted, so the glyphs must match the characters one for one.
            let local = NSRange(token, in: line)
            guard let piece = page.selection(for: NSRange(location: lineRange.location + leading + local.location, length: local.length)),
                  (piece.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(text) else { continue }
            let tokenBox = piece.bounds(for: page)
            // PDFKit sometimes places a token over another part of the line; it should sit about
            // where its share of the characters puts it.
            let share = CGFloat(line.distance(from: line.startIndex, to: token.lowerBound) + text.count / 2) / CGFloat(line.count)
            guard abs(tokenBox.midX - (box.minX + box.width * share)) <= box.width * 0.2 else { continue }
            var glyphs = ink.glyphColumns(in: CGRect(x: tokenBox.minX - 0.5, y: band.minY, width: tokenBox.width + 1, height: band.height))
            // The digits of an exponent such as the "32" of "2³²" can touch; a raised run about as
            // wide as several small digits holds that many.
            if glyphs.count < text.count {
                func bottom(_ run: Range<CGFloat>) -> CGFloat? { ink.lowestInk(in: CGRect(x: run.lowerBound, y: band.minY, width: run.upperBound - run.lowerBound, height: band.height)) }
                let seatedWidths = glyphs.filter { bottom($0).map { abs($0 - baseline) <= 1 } == true }.map { $0.upperBound - $0.lowerBound }.sorted()
                if !seatedWidths.isEmpty {
                    let small = seatedWidths[seatedWidths.count / 2] * 0.7
                    glyphs = glyphs.flatMap { run -> [Range<CGFloat>] in
                        let width = run.upperBound - run.lowerBound
                        let count = Int(((width + 1) / (small + 1)).rounded())
                        guard count > 1, bottom(run).map({ $0 >= baseline + 1.5 }) == true else { return [run] }
                        let step = width / CGFloat(count)
                        return (0..<count).map { (run.lowerBound + step * CGFloat($0))..<(run.lowerBound + step * CGFloat($0 + 1)) }
                    }
                }
            }
            // Glyphs that touch, as the "5)" of "(10⁵)²" or the "09" of "10⁹", are told apart by where PDFKit
            // puts each character, measured in its middle so a neighbour's ink stays out.
            if glyphs.count != text.count, String(text).range(of: #"\)\d+[,.;:]?$|^\D{0,8}10\d{1,2}[,.;:)”]*$"#, options: .regularExpression) != nil {
                let start = lineRange.location + leading + local.location
                // Their widths are right, but the run can sit off where the token is drawn.
                let spans = (0..<local.length).map { page.characterBounds(at: start + $0) }
                if spans.count == text.count, let first = spans.first, let last = spans.last, last.maxX - first.minX > 1, spans.allSatisfy({ $0.width > 0 }),
                   zip(spans, spans.dropFirst()).allSatisfy({ $1.minX >= $0.minX + $0.width * 0.5 }) {
                    let scale = tokenBox.width / (last.maxX - first.minX)
                    glyphs = spans.map { span in
                        let middle = tokenBox.minX + (span.midX - first.minX) * scale, half = span.width * scale * 0.25
                        return (middle - half)..<(middle + half)
                    }
                }
            }
            // Glyphs that touch at one pixel per point, as the "g2" of "log₂(n)", or that sit only a
            // point off the baseline, as the "i" of "aᵢ", are measured again on the line drawn finer.
            let coarse = glyphs
            for pass in 0..<2 {
                var glyphs = coarse, level = baseline
                var measured: [(span: Range<CGFloat>, bottom: CGFloat, top: CGFloat)]?
                if pass == 1 {
                    // Mathematics with accents in a sentence, as "(µ̂₀, π̂b)", is cropped, so its text
                    // is left as it is.
                    guard !line.contains(where: { "ˆ¯˜˙".contains($0) }) else { break }
                    if fine == nil {
                        fine = .some(ink.finer(page).flatMap { map in
                            // The baseline is the middle of the glyphs that end within a pixel of the one
                            // measured at one pixel per point; dots and brackets end elsewhere.
                            let near = map.glyphs(in: band).map(\.bottom).filter { abs($0 - baseline) <= 1 }.sorted()
                            return near.count >= 2 ? (map, near[near.count / 2]) : nil
                        })
                    }
                    guard let (map, fineBaseline) = fine ?? nil else { break }
                    let found = map.glyphs(in: CGRect(x: tokenBox.minX - 0.5, y: band.minY, width: tokenBox.width + 1, height: band.height))
                    glyphs = found.map(\.span)
                    measured = found
                    level = fineBaseline
                    // A power of a function, as "m^gcd(k,n)", is a base well below all that follows it.
                    if String(text).range(of: #"^[a-z][a-z]{2,}\(.*\)[.,]?$"#, options: .regularExpression) != nil, found.count >= text.count - 1,
                       let first = found.first, found.dropFirst().filter({ $0.bottom - first.bottom >= size * 0.25 }).count * 10 >= (found.count - 1) * 7 {
                        result[String(line[whole])] = String(line[whole.lowerBound..<token.lowerBound]) + String(text.first!) + "^(" + String(text.dropFirst()) + ")"
                            + String(line[token.upperBound..<whole.upperBound])
                        break tokens
                    }
                    // A footnote's mark after a long word, as the "1" of "quickselect1,", is told by its
                    // own glyphs, even where two of the word's letters touch.
                    if found.count != text.count, let mark = String(text).firstMatch(of: /^\p{Ll}{4,}(\d{1,2})([.,;:)]?)$/) {
                        let digits = mark.output.1.count, tail = mark.output.2.count
                        let last = Array(found.suffix(digits + tail + 1))
                        if last.count == digits + tail + 1, abs(last[0].bottom - level) <= 1,
                           last[1...digits].allSatisfy({ $0.bottom >= level + size * 0.25 && $0.top > last[0].top - 1 }) {
                            let word = String(text.dropLast(digits + tail)), figures = String(text.dropFirst(text.count - digits - tail).prefix(digits))
                            result[String(line[whole])] = String(line[whole.lowerBound..<token.lowerBound]) + word + String(figures.compactMap { superscripts[$0] })
                                + String(text.suffix(tail)) + String(line[token.upperBound..<whole.upperBound])
                            break tokens
                        }
                    }
                }
                guard glyphs.count == text.count else { continue }
                let bottoms: [CGFloat?] = measured?.map(\.bottom) ?? glyphs.map { ink.lowestInk(in: CGRect(x: $0.lowerBound, y: band.minY, width: $0.upperBound - $0.lowerBound, height: band.height)) }
                let tops: [CGFloat?] = measured?.map(\.top) ?? glyphs.map { ink.highestInk(in: CGRect(x: $0.lowerBound, y: band.minY, width: $0.upperBound - $0.lowerBound, height: band.height)) }
                func height(_ index: Int) -> CGFloat { (tops[index] ?? 0) - (bottoms[index] ?? 0) }
                // The baseline is where letters and digits without descenders sit.
                let resting = text.indices.compactMap { index -> CGFloat? in
                    guard text[index].isNumber || text[index].isLetter && !"gjpqyQ".contains(text[index]) else { return nil }
                    return bottoms[index]
                }
                // A letter with a descender, as the "y" of "y₁", has no glyph on the baseline beside
                // its index; the line's baseline and type size are the measure then.
                let base = text.firstIndex(where: \.isLetter) ?? 0
                // So has an exponent after a bracket, as the "n−x" of "(1 − p)ⁿ⁻ˣ".
                let hanging = base + 1 < text.count && base <= 1 && "gpqy".contains(text[base]) && (text[base + 1].isNumber || text[base + 1].isLetter)
                    || text.firstIndex(of: ")").map { $0 > 0 && text[$0 - 1].isLetter && $0 + 1 < text.count && text[$0 + 1].isLetter } == true
                guard resting.count >= 2 || hanging else { continue }
                // An exponent rides on something that sits on the baseline, as the "2" of "2³¹". Its
                // height is the measure. Ink from the lines above can reach into a letter's columns, so
                // digits are preferred, at their middle height; letters run from x-height to capitals,
                // so the tallest is taken.
                func letter(_ index: Int) -> Bool { text[index].isNumber || text[index].isLetter }
                let seated = text.indices.filter { letter($0) && bottoms[$0].map { abs($0 - level) <= 1 } == true }
                let digits = seated.filter { text[$0].isNumber }
                guard !seated.isEmpty || hanging else { continue }
                // Letters of x-height alone, as the "n" of "n³", understate it; a figure is about two
                // thirds of the type size.
                let seatedHeight = digits.isEmpty ? max(seated.map(height).max() ?? 0, size * 0.65) : digits.map(height).sorted()[digits.count / 2]
                let seatedTop = digits.isEmpty ? max(seated.compactMap { tops[$0] }.max() ?? 0, level + size * 0.65) : digits.compactMap { tops[$0] }.sorted()[digits.count / 2]
                // A raised character stands clear of the baseline; an operator on the maths axis, as the
                // minus of "is −2³¹", stands off it too, so a raised one must stand higher.
                var raised = text.indices.filter { index in
                    guard let bottom = bottoms[index] else { return false }
                    return letter(index) || text[index] == "|" ? bottom >= level + max(1.5, seatedHeight * 0.3)
                        : "+−-=()".contains(text[index]) && bottom >= level + seatedHeight * 0.55
                }
                // A subscript, as the "1" of "a1" or the "i" of "xi", sits below the baseline and stays
                // under the tops of its base; letters that reach down anyway, as "p", are left out.
                if raised.isEmpty {
                    var lowered = text.indices.filter { index in
                        guard letter(index), !"gjpqy".contains(text[index]), let bottom = bottoms[index], let top = tops[index], subscripts[text[index]] != nil else { return false }
                        // A capital index, as the "A" of "S_A", is set much smaller than its base.
                        if text[index].isUppercase, height(index) > seatedHeight * 0.8 || height(index) < seatedHeight * 0.5 { return false }
                        // Drawn finer, a drop of a point is measured, not a pixel's rounding.
                        return bottom <= level - (measured == nil ? max(1, seatedHeight * 0.2) : max(0.9, seatedHeight * 0.14)) && top < seatedTop - seatedHeight * 0.3 && height(index) <= seatedHeight * (measured == nil ? 0.86 : 0.9)
                    }
                    // Letters with descenders reach down anyway; one goes on a subscript, as the "j" of
                    // "Gₙⱼ", when it stays as low as the letter before it.
                    for index in text.indices where "jp".contains(text[index]) && lowered.contains(index - 1) {
                        if let top = tops[index], let before = tops[index - 1], top <= before + seatedHeight * 0.2 { lowered.append(index) }
                    }
                    // A function's index with a descender, as the "q" of "sum_q(a,b)", stays below the
                    // letters' middle.
                    if let name = String(text).firstMatch(of: /^(sum|min|max)[jpq]\(/), let top = tops[name.output.1.count], top <= level + size * 0.33 {
                        lowered.append(name.output.1.count)
                    }
                    // An index can be a sum, as the "n−1" of "Cₙ₋₁"; its sign sits on the index's own axis.
                    for index in text.indices where "−+".contains(text[index]) && lowered.contains(index - 1) && index + 1 < text.count
                        && subscripts[text[index + 1]] != nil {
                        if lowered.contains(index + 1) { lowered.append(index); continue }
                        if let bottom = bottoms[index + 1], let top = tops[index + 1], bottom <= level - 0.9, top < seatedTop - seatedHeight * 0.3 { lowered += [index, index + 1] }
                    }
                    // A word, as "nim", has no subscript letters, whatever its last letter measures; a list
                    // with figures as indices, as "a₁,a₂,...,aₖ", has.
                    let word = String(text.filter(\.isLetter))
                    // A function's name takes a subscript, as "logₖ(x)" or "sum_q".
                    let function = word.range(of: #"^(log|min|max|sum|lim)"#, options: .regularExpression) != nil
                    if !lowered.isEmpty, function || !(lowered.contains { text[$0].isLetter } && !lowered.contains { text[$0].isNumber } && word.count >= 3 && (isDictionaryWord(word.lowercased()) || word.allSatisfy(\.isLowercase))),
                       lowered.allSatisfy({ index in
                        index > 0 && (text[index - 1].isLetter || text[index - 1] == ")" || lowered.contains(index - 1) || text[index - 1].isNumber && lowered.contains(index - 1))
                            && text[index - 1] != " " && !(lowered.contains(index - 1) == false && text[index - 1].isNumber)
                    }) {
                        var written = text
                        for index in lowered { written[index] = subscripts[text[index]]! }
                        let indexed = String(String(written).flatMap { character -> String in
                            guard let scalar = character.unicodeScalars.first, (0xE100...0xE17F).contains(scalar.value) else { return String(character) }
                            return "_" + String(UnicodeScalar(scalar.value - 0xE100)!)
                        })
                        let rewritten = String(line[whole.lowerBound..<token.lowerBound]) + indexed + String(line[token.upperBound..<whole.upperBound])
                        // A line of mathematics is cropped whole; drawn finer, its text is not rewritten
                        // so far that it would read as prose.
                        if measured != nil, looksLikeMath(line), !looksLikeMath(line.replacingCharacters(in: whole, with: rewritten)) { continue }
                        result[String(line[whole])] = rewritten
                        break tokens
                    }
                }
                // Letters drawn finer are read for subscripts only; a raised one, as the "e" of an
                // inline "Pᵉ", is mathematics the line's crop shows.
                if measured != nil, !text.contains(where: \.isNumber), String(text).range(of: #"^O\("#, options: .regularExpression) == nil { continue }
                // It is set smaller and reaches above it, or, measured in whole points, as high when it
                // stands well clear of the baseline; a speck of ink from the line above is not a character.
                // An exponent Unicode cannot write, as the "|S|" of "2^|S|", is written after a caret
                // when it ends the token.
                // A bracket between raised signs is in the exponent only when it stands off the baseline,
                // unlike the ")" of "(10⁵)²".
                func offLine(_ index: Int) -> Bool { !"()".contains(text[index]) || (bottoms[index] ?? level) >= level + 1 }
                let between = text.indices.filter { "()/−+-".contains(text[$0]) && !raised.contains($0) && $0 > 0 && $0 + 1 < text.count && raised.contains($0 - 1) && raised.contains($0 + 1) && offLine($0) }
                let suffix = (raised + between).sorted() == Array((text.count - raised.count - between.count)..<text.count)
                guard !raised.isEmpty, raised.contains(where: letter), raised.allSatisfy({ index in
                    guard let bottom = bottoms[index], let top = tops[index] else { return false }
                    return (superscripts[text[index]] != nil || suffix && (text[index].isLetter || text[index].isNumber || "|()−+".contains(text[index]))) && (!letter(index) || height(index) <= seatedHeight * (!text[index].isASCII ? 0.95 : digits.isEmpty ? 0.85 : 0.8) && height(index) >= seatedHeight * 0.35
                        && (top > seatedTop + 0.5 || top > seatedTop - 0.5 && bottom >= level + seatedHeight * 0.45))
                }) else { continue }
                // An operator between two raised characters, as the "/" of "2ⁿᐟ²" or the "−" of
                // "2ⁿ⁻¹", is part of the exponent even where it sits low.
                for index in text.indices where "/−+-()".contains(text[index]) && !raised.contains(index) && offLine(index)
                    && index > 0 && index + 1 < text.count && raised.contains(index - 1) && raised.contains(index + 1) {
                    raised.append(index)
                }
                // A raised letter rides on a base, as the "k" of "nᵏ"; one that opens the token, as
                // the "x" of "xᵢ)" over its subscript, only looks raised.
                if raised.contains(where: { text[$0].isLetter && ($0 == 0 || !(text[$0 - 1].isLetter || text[$0 - 1].isNumber || text[$0 - 1] == ")" || raised.contains($0 - 1))) }) { continue }
                // An exponent that goes on unraised, as the "/" of "2^(n/2)" or the "−" of "2^(n−1)", is
                // only partly seen; the token is left as it is.
                if raised.contains(where: { index in
                    let before = index > 0 ? text[index - 1] : " "
                    return !raised.contains(index - 1) && (before == "/" || before.isNumber && index > 1 && text[index - 2] == ")" || "−+-".contains(before) && index > 1 && (text[index - 2].isLetter || text[index - 2].isNumber))
                        || index + 1 < text.count && !raised.contains(index + 1) && text[index + 1] == "/"
                }) { continue }
                // Raised characters that open a token mark a footnote on the word they precede, as in
                // "¹Cornell"; before a digit, as the "1" of "17M" would be, they are misread ink.
                if raised.contains(text.startIndex), let first = text.indices.first(where: { !raised.contains($0) }), !text[first].isLetter { continue }
                // Drawn finer, an exponent that opens with a sign, as the "−2" of "7.5e^(−2d̄(x,a))",
                // goes on in the next piece of the row, where the line's crop shows it.
                if measured != nil, let first = raised.min(), "−+-".contains(text[first]) { continue }
                var lifted = raised
                // A two-figure power of ten, as "10³⁸", is raised whole when its last figure is.
                if let ten = String(text).range(of: #"10\d\d"#, options: .regularExpression) {
                    let start = String(text).distance(from: String(text).startIndex, to: ten.lowerBound)
                    if lifted.contains(start + 3), !lifted.contains(start + 2) { lifted.append(start + 2) }
                }
                var written = text
                if lifted.allSatisfy({ superscripts[text[$0]] != nil }) {
                    for index in lifted { written[index] = superscripts[text[index]]! }
                } else {
                    // More than one sign goes in brackets: "x^(ϕ(m)−1)".
                    let exponent = String(text[lifted.min()!...])
                    // An ordinal's letters, as the "th" of "99th", are no exponent.
                    // One that opens with a sign, as the "−s" of "e^(−s′)", goes on past the token.
                    if exponent.range(of: #"^(st|nd|rd|th)[.,;:]?$|^[−+-]"#, options: .regularExpression) != nil { continue }
                    written = Array(text[..<lifted.min()!]) + Array("^" + (exponent.count == 1 || exponent.hasPrefix("(") && exponent.hasSuffix(")") || exponent.hasPrefix("|") && exponent.hasSuffix("|") ? exponent : "(" + exponent + ")"))
                }
                let rewritten = String(line[whole.lowerBound..<token.lowerBound]) + String(written) + String(line[token.upperBound..<whole.upperBound])
                if measured != nil, looksLikeMath(line), !looksLikeMath(line.replacingCharacters(in: whole, with: rewritten)) { continue }
                result[String(line[whole])] = rewritten
                break tokens
            }
          }
        }
        // An exponent PDFKit set apart from its base, as the "n" of "X n" for "Xⁿ", stands clear
        // above the baseline on its own.
        let all = Array(line.ranges(of: /\S+/))
        for position in all.indices.dropFirst() {
            let base = line[all[position - 1]], power = line[all[position]]
            guard base.count == 1, base.first!.isUppercase, power.count == 1, let small = superscripts[power.first!], power.first!.isLetter,
                  result[String(base)] == nil else { continue }
            let local = NSRange(all[position], in: line)
            guard let piece = page.selection(for: NSRange(location: lineRange.location + leading + local.location, length: local.length)),
                  (piece.string ?? "").trimmingCharacters(in: .whitespaces) == String(power) else { continue }
            let box = piece.bounds(for: page)
            guard let bottom = ink.lowestInk(in: CGRect(x: box.minX, y: band.minY, width: box.width, height: band.height)),
                  bottom >= baseline + size * 0.3 else { continue }
            result[String(base) + " " + String(power)] = String(base) + String(small)
        }
        return result
    }

    /// A radical sign drawn without a character leaves a space, as "O( n)" for "O(√n)" or
    /// "size n" for "size √n". Where that space holds a sign reaching below the line and a
    /// rule runs over the next token, the root is written back.
    private static func radicals(in line: String, selection: PDFSelection, page: PDFPage, ink: InkMap) -> [String: String] {
        guard line.contains(" "), selection.numberOfTextRanges(on: page) == 1, let raw = selection.string,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == line else { return [:] }
        let lineRange = selection.range(at: 0, on: page)
        guard lineRange.location != NSNotFound else { return [:] }
        let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        var sizes: [CGFloat: Int] = [:]
        if let attributed = selection.attributedString {
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                if let size = (font as? NSFont)?.pointSize { sizes[size, default: 0] += range.length }
            }
        }
        guard let size = sizes.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key, size > 0 else { return [:] }
        var box = ink.withoutRules(selection.bounds(for: page).insetBy(dx: 0, dy: -2))
        // A box stretched over the next line is cut to the band of ink that is the line's own.
        if box.height > size * 1.6, let own = ink.rowBands(in: box).filter({ $0.lowerBound > box.minY + 0.5 && $0.upperBound < box.maxY - 0.5 }).max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }),
           own.upperBound - own.lowerBound > size * 0.5 {
            box = CGRect(x: box.minX, y: own.lowerBound - 1, width: box.width, height: own.upperBound - own.lowerBound + 2)
        }
        // The baseline is where most glyphs end; ink cut off by the box's edge belongs to another line.
        let bottoms = ink.glyphColumns(in: box).compactMap { ink.lowestInk(in: CGRect(x: $0.lowerBound, y: box.minY, width: $0.upperBound - $0.lowerBound, height: box.height)) }
            .filter { $0 > box.minY + 0.5 }
        let tally = Dictionary(grouping: bottoms.map { ($0 * 2).rounded() / 2 }, by: { $0 }).mapValues(\.count)
        guard let baseline = tally.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key, tally[baseline, default: 0] >= 3 else { return [:] }
        let tokens = Array(line.ranges(of: /\S+/))
        func bounds(_ token: Range<String.Index>) -> CGRect? {
            let local = NSRange(token, in: line)
            guard let piece = page.selection(for: NSRange(location: lineRange.location + leading + local.location, length: local.length)),
                  (piece.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(line[token]) else { return nil }
            let rect = piece.bounds(for: page)
            return rect.width > 0 ? rect : nil
        }
        var result: [String: String] = [:]
        for position in tokens.indices.dropFirst() {
            let previous = tokens[position - 1], next = tokens[position]
            let sign = line[next].prefix { "−-".contains($0) }
            let radicand = sign + line[next].dropFirst(sign.count).prefix { $0.isLetter || $0.isNumber }
            guard (1...4).contains(radicand.count - sign.count), radicand.count <= 2 || !isDictionaryWord(String(radicand).lowercased()),
                  let after = bounds(next) else { continue }
            // PDFKit's boxes can take in the sign; the rule over the radicand tells it. It runs level
            // over the radicand's first and last letters, above where letters reach.
            let share = after.width * CGFloat(radicand.count) / CGFloat(line[next].count)
            let band = CGRect(x: 0, y: baseline + size * 0.76, width: 0, height: size * 0.45)
            // The rule is the top of the ink over the letters, or, where the line above reaches
            // down into the band, the first ink over them.
            let columns = [after.minX + 0.5, after.minX + share - 1.5].map { CGRect(x: $0, y: band.minY, width: 1, height: band.height) }
            let highest = columns.map { ink.highestInk(in: $0) }, lowest = columns.map { ink.lowestInk(in: $0) }
            let level = { (pair: [CGFloat?]) -> Bool in pair[0] != nil && pair[1] != nil && abs(pair[0]! - pair[1]!) <= 1 }
            let tops = level(highest) ? highest : lowest
            guard let left = tops[0], let right = tops[1], abs(left - right) <= 1, left < band.maxY - 1 else { continue }
            // The rule is unbroken from the sign across the radicand, with little just above it;
            // the descenders of the line above are neither.
            let steps = Array(stride(from: after.minX - 1.5, through: after.minX + share - 1, by: 0.5))
            guard steps.filter({ ink.inked(CGRect(x: $0, y: left - 1.5, width: 0.5, height: 2)) }).count * 10 >= steps.count * 9,
                  steps.filter({ ink.inked(CGRect(x: $0, y: left + 1.8, width: 0.5, height: 1)) }).count * 10 <= steps.count * 4,
                  // and starts at the sign, unlike a table's rule over a row of figures; a tall letter
                  // of the word before, as the "f" of "of", is no rule.
                  Array(stride(from: after.minX - size * 1.3, through: after.minX - size * 1.05, by: 0.5))
                    .filter({ ink.inked(CGRect(x: $0, y: left - 0.7, width: 0.5, height: 1.2)) }).count * 10 < 7 * Int((size * 0.25 / 0.5).rounded(.down) + 1) else { continue }
            // The sign itself stands just before the radicand, from below the line up to the rule.
            let root = CGRect(x: after.minX - size * 0.9, y: baseline - size * 0.4, width: size * 0.9, height: left - baseline + size * 0.4 + 0.5)
            guard let low = ink.lowestInk(in: root), low <= baseline - size * 0.08,
                  let high = ink.highestInk(in: CGRect(x: after.minX - size * 0.9, y: root.minY, width: size * 0.9, height: root.height + 1)), high >= left - 1 else { continue }
            let joined = line[previous].last.map { "([{⌊⌈".contains($0) } == true
            let key = String(line[previous]) + " " + String(line[next])
            result[key] = String(line[previous]) + (joined ? "" : " ") + "√" + String(line[next])
        }
        var chained: (key: String, value: String, end: Int)?
        // Other signs drawn without a character, in the space between two tokens: "···" in
        // "X1 + X2 + + Xn" and "∅" in "mex( )".
        for position in tokens.indices.dropFirst() {
            let previous = tokens[position - 1], next = tokens[position]
            let key = String(line[previous]) + " " + String(line[next])
            // PDFKit's box for the token before can take in the space and the sign; the token
            // ends where its own characters, as typeset, do.
            guard result[key] == nil || chained?.end == position - 1, var before = bounds(previous), let after = bounds(next) else { continue }
            let local = NSRange(previous, in: line)
            if let typeset = page.selection(for: NSRange(location: lineRange.location + leading + local.location, length: local.length))?.attributedString?.size().width,
               typeset > 1, typeset < before.width {
                before.size.width = typeset
            }
            guard after.minX - before.maxX >= size * 0.45 else { continue }
            let gap = CGRect(x: before.maxX + 0.4, y: baseline - size * 0.35, width: after.minX - before.maxX - 0.8, height: size * 1.25)
            let runs = ink.glyphColumns(in: gap)
            guard !runs.isEmpty else { continue }
            func extent(_ run: Range<CGFloat>) -> (low: CGFloat, high: CGFloat)? {
                let column = CGRect(x: run.lowerBound, y: gap.minY, width: run.upperBound - run.lowerBound, height: gap.height)
                guard let low = ink.lowestInk(in: column), let high = ink.highestInk(in: column) else { return nil }
                return (low, high)
            }
            let extents = runs.compactMap(extent)
            guard extents.count == runs.count else { continue }
            let open = line[previous].last.map { "([{".contains($0) } == true
            var sign: String?
            if runs.count == 3, zip(runs, extents).allSatisfy({ $0.upperBound - $0.lowerBound <= size * 0.2 && $1.high - $1.low <= size * 0.2 }),
               Set(extents.map { ($0.low * 2).rounded() }).count == 1 {
                sign = "⋯"
            } else if let fine = ink.finer(page) {
                // Drawn finer, each glyph in the space is told by its shape, as the ring and stroke
                // of "∅" in "The symbol ∅ denotes" or "are ∅, {2}".
                sign = fine.signs(in: gap, baseline: baseline, size: size)
            }
            guard var sign else { continue }
            // A comma the box of the token before left out is that token's own.
            if sign.hasPrefix(","), line[previous].hasSuffix(",") { sign.removeFirst() }
            if sign.hasSuffix(","), line[next].hasPrefix(",") { sign.removeLast() }
            guard !sign.isEmpty else { continue }
            // Box characters run together, as "⊔⊏⊐⊔⊓⊓⊔".
            let boxes = "⊓⊔⊏⊐□"
            let glued = sign.allSatisfy { boxes.contains($0) }
            let closing = line[next].first.map { ")}],;.".contains($0) } == true || glued && line[next].first.map { boxes.contains($0) } == true
            let opening = open || glued && line[previous].last.map { boxes.contains($0) } == true
            let value = String(line[previous]) + (opening ? "" : " ") + sign + (closing && !sign.hasSuffix(",") ? "" : " ") + String(line[next])
            // Signs in neighbouring spaces, as the "⊏" and "⊐" of "{⊓, ⊔, ⊏, ⊐}", share a token; the
            // pieces are rewritten as one.
            if let last = chained, last.end == position - 1 {
                result[last.key] = nil
                let joined = last.key + " " + String(line[next]), rewritten = last.value + String(value.dropFirst(line[previous].count))
                result[joined] = rewritten
                chained = (joined, rewritten, position)
            } else {
                result[key] = value
                chained = (key, value, position)
            }
        }
        return result
    }

    /// PDFKit ends a line after a raised character, so "any integer between 0 and 2³²" and
    /// "− 1. For example, in C++" come as two lines of one row. The rest of the row joins the line
    /// it continues, and the sentence reads as one.
    private static func rejoinRaisedSplits(_ found: inout [(selection: PDFSelection, text: String)], respacedTokens: inout [[String: String]],
                                           raised: [[String: String]], on page: PDFPage) {
        var raised = raised
        var index = 0
        while index < found.count {
            let own = found[index].selection.bounds(for: page)
            guard let last = found[index].text.split(whereSeparator: \.isWhitespace).last,
                  let next = found.indices.first(where: { other in
                      let box = found[other].selection.bounds(for: page)
                      // A note beside the body, set in another size, is no part of its row.
                      if let a = fontSize(of: found[index].selection), let b = fontSize(of: found[other].selection), abs(a - b) > max(a, b) * 0.1 { return false }
                      return other != index && (-1...4).contains(box.minX - own.maxX)
                          && min(own.maxY, box.maxY) - max(own.minY, box.minY) > min(own.height, box.height) * 0.5
                  }),
                  raised[index][String(last)] != nil || raised[index].values.contains(String(last)) else {
                index += 1
                continue
            }
            let selection = found[index].selection.copy() as? PDFSelection ?? found[index].selection
            selection.add(found[next].selection)
            // Tokens are rewritten while they stand alone, before a full stop can join one.
            var tail = found[next].text
            for (token, spaced) in respacedTokens[next].sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) {
                tail = tail.replacingOccurrences(of: #"(?<!\S)"# + NSRegularExpression.escapedPattern(for: token) + #"(?!\S)"#,
                                                 with: NSRegularExpression.escapedTemplate(for: spaced), options: .regularExpression)
            }
            if found[index].text.hasSuffix(String(last)), let spaced = respacedTokens[index][String(last)], tail.first.map({ ".,;:".contains($0) }) == true {
                found[index].text = String(found[index].text.dropLast(last.count)) + spaced
            }
            let separator = tail.first.map { ".,;:".contains($0) } == true ? "" : " "
            found[index] = (selection, found[index].text + separator + tail)
            raised[index] = raised[next]
            found.remove(at: next)
            respacedTokens.remove(at: next)
            raised.remove(at: next)
            if next < index { index -= 1 }
        }
    }

    /// A binomial or a fraction set in a sentence, as "There are a total of (2n over n) ways",
    /// comes as two pieces of one row: the line ends on the top, "…total of 2n", and the next piece
    /// starts with the bottom, "n ways…", set under it; the top's piece holds a word of the sentence. Tall brackets beside them make a binomial,
    /// "C(2n, n)"; a bar between them a fraction, "1/2".
    private static func rewriteStackedPairs(_ found: inout [(selection: PDFSelection, text: String)], respacedTokens: inout [[String: String]],
                                            on page: PDFPage, ink: InkMap) {
        func box(of token: Range<String.Index>, in index: Int) -> CGRect? {
            let (selection, text) = found[index]
            guard selection.numberOfTextRanges(on: page) == 1, let raw = selection.string, raw.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return nil }
            let range = selection.range(at: 0, on: page)
            let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
            let local = NSRange(token, in: text)
            guard range.location != NSNotFound, let piece = page.selection(for: NSRange(location: range.location + leading + local.location, length: local.length)),
                  (piece.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(text[token]) else { return nil }
            let rect = piece.bounds(for: page)
            return rect.width > 0 ? rect : nil
        }
        func operand(_ token: Substring) -> Bool {
            token.range(of: #"^[\p{L}\p{N}+−-]{1,6}$"#, options: .regularExpression) != nil && !(token.count >= 2 && token.allSatisfy(\.isLetter) && isDictionaryWord(token.lowercased()))
        }
        var removed: [Int] = []
        for index in found.indices {
            guard let last = found[index].text.ranges(of: /\S+/).last, operand(found[index].text[last]),
                  found[index].text.split(whereSeparator: \.isWhitespace).contains(where: { $0.count >= 3 && isDictionaryWord(wordLetters($0).lowercased()) }),
                  let top = box(of: last, in: index) else { continue }
            for other in found.indices where other != index && !removed.contains(other) {
                guard let first = found[other].text.ranges(of: /\S+/).first, operand(found[other].text[first]), let bottom = box(of: first, in: other) else { continue }
                // Set under the top, on the same row of the page.
                let overlap = min(top.maxX, bottom.maxX) - max(top.minX, bottom.minX)
                guard overlap >= min(top.width, bottom.width) * 0.5, bottom.midY < top.midY - 2, top.midY - bottom.midY < top.height * 0.8 else { continue }
                let span = CGRect(x: min(top.minX, bottom.minX), y: bottom.minY, width: max(top.maxX, bottom.maxX) - min(top.minX, bottom.minX), height: top.maxY - bottom.minY)
                // A bracket as tall as both, just before them, or a rule between them.
                let bracket = ink.glyphColumns(in: CGRect(x: span.minX - 6, y: span.minY, width: 6, height: span.height)).contains { run in
                    let column = CGRect(x: run.lowerBound, y: span.minY, width: run.upperBound - run.lowerBound, height: span.height)
                    guard run.lowerBound < span.minX, run.upperBound <= span.minX + 1.5, run.upperBound - run.lowerBound <= 4,
                          let high = ink.highestInk(in: column), let low = ink.lowestInk(in: column) else { return false }
                    return high - low >= span.height * 0.65
                }
                let middle = CGRect(x: span.minX, y: bottom.midY, width: span.width, height: max(0, top.midY - bottom.midY))
                let bar = ink.rowBands(in: middle).contains { $0.upperBound - $0.lowerBound <= 1.5 } && ink.glyphColumns(in: middle).contains { $0.upperBound - $0.lowerBound >= span.width * 0.7 }
                guard bracket || bar else { continue }
                let upper = String(found[index].text[last]), lower = String(found[other].text[first])
                found[index].text = String(found[index].text[..<last.lowerBound]) + (bracket ? "C(\(upper), \(lower))" : "\(upper)/\(lower)")
                let rest = found[other].text[first.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { removed.append(other) } else { found[other].text = rest }
                break
            }
        }
        for index in removed.sorted(by: >) {
            found.remove(at: index)
            respacedTokens.remove(at: index)
        }
    }

    /// Two-letter words; dictionaries also accept abbreviations such as "dk" or "dv".
    private static let shortWords: Set<String> = ["is", "of", "to", "in", "or", "as", "by", "at", "on", "so", "be", "an", "we", "it", "if", "no", "up", "do", "us", "my", "he", "me"]

    /// A word the dictionary knows. Spelling checkers pass any capitals as an acronym, so names
    /// such as "WQ" or "KWK" need a lowercase letter.
    private static func isDictionaryWord(_ letters: String) -> Bool {
        letters.count <= 2 ? shortWords.contains(letters.lowercased()) : letters.contains(where: \.isLowercase) && WordSplitter.isWord(letters)
    }

    /// The tokens at the start or end of a line that are not dictionary words, such as "WQ" in
    /// "parameter matrices WQ" or "i=1 qiki," in "i=1 qiki, has mean 0", with where they sit.
    private static func edgeSymbols(in line: String, leading atStart: Bool, selection: PDFSelection, page: PDFPage, pageText: NSString) -> (range: Range<String.Index>, rect: CGRect, previousEnd: CGFloat?, nextStart: CGFloat?)? {
        guard selection.numberOfTextRanges(on: page) == 1, let raw = selection.string,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == line else { return nil }
        let tokens = line.ranges(of: /\S+/)
        // A name, as the "Chernozhukov" of a citation, is no symbol either.
        func symbol(_ token: Range<String.Index>) -> Bool {
            let letters = wordLetters(line[token])
            return line[token].count <= 16 && !(letters.count >= 2 && isDictionaryWord(letters))
                && line[token].range(of: #"^[(\[]?\p{Lu}\p{Ll}{3,}"#, options: .regularExpression) == nil
        }
        var run = atStart ? Array(tokens.prefix { symbol($0) }) : Array(tokens.reversed().prefix { symbol($0) }.reversed())
        // The number of a reference, as the "1," of "Theorem 1,", belongs to the sentence.
        while !atStart, let head = run.first, line[head].range(of: #"^\d+(\.\d+)*[,.;:]?$"#, options: .regularExpression) != nil,
              let before = tokens.last(where: { $0.upperBound <= head.lowerBound }),
              line[before].range(of: #"^(Theorem|Lemma|Corollary|Proposition|Definition|Assumption|Equation|Eq\.|Section|Figure|Fig\.|Table|Chapter|Appendix|Algorithm|Step)$"#, options: .regularExpression) != nil {
            run.removeFirst()
        }
        guard let first = run.first, let last = run.last, run.count < tokens.count else { return nil }
        let range = first.lowerBound..<last.upperBound
        let lineRange = selection.range(at: 0, on: page)
        let leading = (raw as NSString).range(of: #"^\s*"#, options: .regularExpression).length
        func onPage(_ range: Range<String.Index>) -> CGRect? {
            let local = NSRange(range, in: line)
            let pageRange = NSRange(location: lineRange.location + leading + local.location, length: local.length)
            guard lineRange.location != NSNotFound, NSMaxRange(pageRange) <= pageText.length, pageText.substring(with: pageRange) == String(line[range]),
                  let piece = page.selection(for: pageRange), (piece.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(line[range]) else { return nil }
            return piece.bounds(for: page)
        }
        guard let rect = onPage(range) else { return nil }
        let next = atStart ? tokens.first { $0.lowerBound >= range.upperBound } : nil
        let previous = atStart ? nil : tokens.last { $0.upperBound <= range.lowerBound }
        return (range, rect, previous.flatMap(onPage)?.maxX, next.flatMap(onPage)?.minX)
    }

    static func isMarker(_ line: String) -> Bool {
        line.hasPrefix(markerPrefix)
    }

    /// Removes markers from `text` and returns the figures they stand for, positioned by word.
    static func resolveFigures(in text: String, figures: [PageFigure]) -> (text: String, figures: [SectionFigure]) {
        var words = 0
        var found: [SectionFigure] = []
        for token in TextProcessor.tokenizedText(text).tokens {
            if token.text.hasPrefix(markerPrefix), let number = Int(token.text.dropFirst(markerPrefix.count)), figures.indices.contains(number) {
                let figure = figures[number]
                found.append(SectionFigure(kind: figure.kind, wordIndex: words, imageData: figure.imageData, text: figure.text))
            } else {
                words += 1
            }
        }
        let cleaned = text.replacingOccurrences(of: markerPrefix + #"\d+"#, with: "", options: .regularExpression)
        return (TextProcessor.normalizedText(cleaned), found)
    }

    // MARK: Line classification

    // PDFKit reports a placeholder font for extracted text, so lines are classified by shape.

    // MARK: Word spacing

    /// Some PDFs, often from LaTeX, position words without storing spaces between them, and
    /// PDFKit then reports lines like "limitedtreatmentBforpeople". Such lines get the word
    /// breaks that text recognition sees on the rendered page, while keeping their own characters.
    private static func respaceRunTogetherLines(_ original: inout [(selection: PDFSelection, text: String)], on page: PDFPage, bounds: CGRect) {
        // Code, as "from sklearn.linear_model import LinearRegression", has its spaces where they
        // belong.
        let code = Set(original.indices.filter { index in
            // PDFKit can name a substitute font, so a numbered line of code is known by its words.
            if original[index].text.range(of: #"^\d{1,3}\s+(from|import|def|class|return|print|for|while|if|elif|else)\b"#, options: .regularExpression) != nil { return true }
            guard let attributed = original[index].selection.attributedString, attributed.length > 0 else { return false }
            var fixed = 0
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                if let font = font as? NSFont, font.isFixedPitch || font.fontName.range(of: "Mono|Courier|Typewriter|Consol|Menlo|Inconsolata", options: .regularExpression) != nil { fixed += range.length }
            }
            return fixed * 2 > attributed.length
        })
        var lines = original
        defer { for index in lines.indices where !code.contains(index) { original[index].text = lines[index].text } }
        // One odd line, such as a string example, is not enough: the page must show the problem twice.
        let missing = lines.filter { missingSpaces($0.text) }
        let glaring = missing.contains { $0.text.range(of: #"\p{Ll}{25,}"#, options: .regularExpression) != nil }
        guard missing.count >= 2 || glaring else {
            // A single joined pair such as "nonrandomizedstudies" is split with the dictionary alone.
            for index in lines.indices where missingSpaces(lines[index].text) {
                lines[index].text = WordSplitter.split(lines[index].text)
            }
            return
        }
        let suspicious = lines.indices.filter { runsTogether(lines[$0].text) }
        defer {
            // Lines set tightly enough to fool recognition are split with the dictionary:
            // "TerminologyDefancified" at the capital, "anideaofwhat" into "an idea of what".
            // Only pages that show the problem are touched, so other PDFs keep their words.
            for index in lines.indices {
                lines[index].text = WordSplitter.split(splitJoinedCapitals(lines[index].text))
            }
        }
        guard !suspicious.isEmpty, let recognized = recognizedLines(on: page, bounds: bounds) else { return }
        for index in suspicious {
            let rect = lines[index].selection.bounds(for: page)
            let matching = recognized.filter { line in
                let overlap = min(line.rect.maxY, rect.maxY) - max(line.rect.minY, rect.minY)
                return overlap > min(line.rect.height, rect.height) * 0.5 && line.rect.intersects(rect.insetBy(dx: -2, dy: 0))
            }
            guard !matching.isEmpty else { continue }
            let reference = matching.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
            if let spaced = respaced(lines[index].text, like: reference) {
                lines[index].text = spaced
            }
        }
    }

    /// Puts a space before each capital that follows a lowercase letter, inside runs of 15 or
    /// more letters only, so names like "McDonald" are left alone.
    static func splitJoinedCapitals(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\p{L}{15,}"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var split = ""
            var previous: Character?
            for character in result[range] {
                if let previous, previous.isLowercase, character.isUppercase { split.append(" ") }
                split.append(character)
                previous = character
            }
            result.replaceSubrange(range, with: split)
        }
        return result
    }

    /// Strong signs that the page lost its spaces: a run of 15 or more letters, or a long line
    /// with hardly any spaces. Names such as "HackerRank" are not enough on their own.
    private static func missingSpaces(_ text: String) -> Bool {
        // Runs of mostly lowercase letters; "ACBACDACBACBACDA" is data, not lost spaces.
        if let pattern = try? NSRegularExpression(pattern: #"\p{L}{15,}"#) {
            let source = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let run = source.substring(with: match.range)
                // Real long words such as "implementations" are fine.
                if run.filter(\.isLowercase).count * 10 >= run.count * 7, !WordSplitter.isWord(run) { return true }
            }
        }
        // A long line with hardly any spaces, made of letters; code like `cout<<s.count(5);` is not.
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let visible = text.filter { !$0.isWhitespace }
        return text.count >= 40 && tokens.count * 14 < text.count && visible.filter(\.isLetter).count * 4 >= visible.count * 3
    }

    /// A run of 15 or more letters, or a long line with hardly any spaces. Real words that long
    /// are rare, and a line flagged by mistake keeps its spacing, since recognition agrees.
    /// Addresses and code are left alone, since recognition splits them in odd places.
    private static func runsTogether(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        if missingSpaces(text) { return true }
        // Words joined at a capital, as in "YouMightCare" or "TheFlow".
        if text.range(of: #"\p{Ll}{2,}\p{Lu}\p{Ll}{2,}"#, options: .regularExpression) != nil { return true }
        // A math letter such as 𝑌 run into the next word, as in "𝑌among".
        if text.range(of: #"[\x{1D400}-\x{1D7FF}]\p{Ll}{2,}|\p{Ll}{2,}[\x{1D400}-\x{1D7FF}]"#, options: .regularExpression) != nil { return true }
        return text.count >= 40 && tokens.count * 14 < text.count
    }

    private static func recognizedLines(on page: PDFPage, bounds: CGRect) -> [(text: String, rect: CGRect)]? {
        let scale: CGFloat = 2.5
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        // Fast recognition misreads some letters, but only its word breaks are used.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, CGRect(x: bounds.minX + box.minX * bounds.width, y: bounds.minY + box.minY * bounds.height,
                                 width: box.width * bounds.width, height: box.height * bounds.height))
        }
    }

    /// Copies the word breaks of `reference` onto `text` by aligning the two character by
    /// character, so misread or missing characters do not shift the breaks. Returns nil when
    /// the two do not line up well enough.
    static func respaced(_ text: String, like reference: String) -> String? {
        func normalized(_ character: Character) -> Character {
            String(character).precomposedStringWithCompatibilityMapping.lowercased().first ?? character
        }
        var guide: [Character] = []
        var spaceBefore: [Bool] = []
        var pendingSpace = false
        for character in reference {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                guide.append(normalized(character))
                spaceBefore.append(pendingSpace)
                pendingSpace = false
            }
        }
        let original = Array(text).filter { !$0.isWhitespace }
        let source = original.map(normalized)
        guard !source.isEmpty, !guide.isEmpty else { return nil }

        // Edit-distance alignment: matching characters cost nothing, a substitution or a gap costs one.
        let rows = source.count + 1, columns = guide.count + 1
        var cost = [Int](repeating: 0, count: rows * columns)
        for i in 0..<rows { cost[i * columns] = i }
        for j in 0..<columns { cost[j] = j }
        for i in 1..<rows {
            for j in 1..<columns {
                let diagonal = cost[(i - 1) * columns + j - 1] + (source[i - 1] == guide[j - 1] ? 0 : 1)
                cost[i * columns + j] = min(diagonal, cost[(i - 1) * columns + j] + 1, cost[i * columns + j - 1] + 1)
            }
        }
        var aligned = [Int?](repeating: nil, count: source.count)
        var i = source.count, j = guide.count, matched = 0
        while i > 0, j > 0 {
            let here = cost[i * columns + j]
            if here == cost[(i - 1) * columns + j - 1] + (source[i - 1] == guide[j - 1] ? 0 : 1) {
                aligned[i - 1] = j - 1
                if source[i - 1] == guide[j - 1] { matched += 1 }
                i -= 1; j -= 1
            } else if here == cost[(i - 1) * columns + j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        guard Double(matched) / Double(source.count) >= 0.7 else { return nil }

        // Spaces the PDF already has are kept; recognition only adds the missing ones.
        var originalSpaceBefore = [Bool](repeating: false, count: original.count)
        var seen = 0, pending = false
        for character in text {
            if character.isWhitespace { pending = true; continue }
            originalSpaceBefore[seen] = pending
            pending = false
            seen += 1
        }
        // A token that is already a real word keeps its letters together; recognition sometimes
        // breaks justified text in odd places, as in "represent ative".
        var keepWhole = [Bool](repeating: false, count: original.count)
        var start = 0
        while start < original.count {
            var end = start + 1
            while end < original.count, !originalSpaceBefore[end] { end += 1 }
            let letters = String(original[start..<end]).trimmingCharacters(in: .punctuationCharacters)
            if letters.count >= 2, letters.allSatisfy(\.isLetter), WordSplitter.isWord(letters) {
                for index in start..<end { keepWhole[index] = true }
            }
            start = end
        }
        var output = ""
        var previous = -1
        for (index, character) in original.enumerated() {
            var space = originalSpaceBefore[index]
            if let position = aligned[index] {
                // Never before closing punctuation or after an opening bracket.
                if index > 0, !keepWhole[index] || originalSpaceBefore[index], !")]}.,;:!?".contains(character), !"([{".contains(original[index - 1]),
                   (previous + 1...position).contains(where: { spaceBefore[$0] }) { space = true }
                previous = position
            }
            if space, index > 0 { output.append(" ") }
            output.append(character)
        }
        return rejoiningLoneLetters(output)
    }

    /// Text recognition sometimes cuts letters off an unfamiliar word, as in "Unconfoundedne s s".
    /// A lone lowercase letter after a fragment that is not a word goes back onto it.
    static func rejoiningLoneLetters(_ text: String) -> String {
        var parts = text.components(separatedBy: " ")
        var index = 1
        while index < parts.count {
            let piece = parts[index], previous = parts[index - 1]
            let bare = previous.trimmingCharacters(in: .punctuationCharacters)
            if piece.count == 1, piece.first?.isLowercase == true, !["a", "i"].contains(piece),
               bare.count >= 4, bare.allSatisfy(\.isLetter), !WordSplitter.isWord(bare) {
                parts[index - 1] = previous + piece
                parts.remove(at: index)
            } else {
                index += 1
            }
        }
        return parts.joined(separator: " ")
    }

    /// Code fonts place every glyph in a cell of the same width, so the distance between the
    /// centres of neighbouring glyphs is constant; in proportional prose it varies widely.
    private static func isMonospaced(_ selection: PDFSelection, on page: PDFPage, text: NSString, line: String) -> Bool {
        guard selection.numberOfTextRanges(on: page) > 0 else { return false }
        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound, range.length > 1, NSMaxRange(range) <= text.length else { return false }
        // Digits share one width in most fonts, so rows of numbers are not code, and code
        // nearly always has some punctuation that prose lacks.
        // Dot leaders in a table of contents are evenly spaced too.
        // A sentence with no statement syntax is prose, whatever its letter spacing suggests.
        let words = line.split(whereSeparator: \.isWhitespace).filter(isWord).count
        if words >= 6, line.range(of: #"[;{}=]|//"#, options: .regularExpression) == nil { return false }
        guard line.unicodeScalars.filter(CharacterSet.letters.contains).count >= 3,
              line.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}=;_<>#/\"'`*+%&|")) != nil,
              !line.contains(". . .")
        else { return false }
        var advances: [CGFloat] = []
        for index in range.location..<(NSMaxRange(range) - 1) where text.character(at: index) != 32 && text.character(at: index + 1) != 32 {
            advances.append(page.characterBounds(at: index + 1).midX - page.characterBounds(at: index).midX)
        }
        guard advances.count >= 8 else { return false }
        let median = advances.sorted()[advances.count / 2]
        guard median > 0 else { return false }
        let uniform = advances.filter { abs($0 - median) <= median * 0.12 }.count
        return Double(uniform) / Double(advances.count) >= 0.8
    }

    /// Program text recognised from what it says, for PDFs whose letter positions cannot be
    /// trusted: statements such as `import numpy as np`, `x = f(y)` or `model.fit(Xt, y)`,
    /// with few real words and no mathematical letters.
    static func looksLikeCode(_ text: String) -> Bool {
        let body = text.replacingOccurrences(of: #"^\d{1,3}\s+"#, with: "", options: .regularExpression)
        // Math letters and the private glyphs TeX uses for big brackets mean mathematics.
        guard !body.unicodeScalars.contains(where: { (0x1D400...0x1D7FF).contains($0.value) || (0xE000...0xF8FF).contains($0.value) }) else { return false }
        // Statements whose shape cannot be prose count whatever their words.
        let statements = [
            #"^import [\w.]+( as \w+)?$"#, #"^from [\w.]+ import "#, #"^def \w+\("#, #"^class \w+[(:]"#,
            #"^print\("#, #"^#include"#, #"^using namespace"#
        ]
        if statements.contains(where: { body.range(of: $0, options: .regularExpression) != nil }) { return true }
        let patterns = [
            #"^[A-Za-z_][\w\[\]'".]*\s*=\s*\S"#,
            #"[A-Za-z_]\w*\.[A-Za-z_]\w*\("#,
            #"\w\[['"]"#,
            #";\s*$|^\s*[{}]\s*$"#,
            // A function or loop header opening its body: "int sum(int a, int b) {".
            #"\)\s*\{\s*$"#
        ]
        guard patterns.contains(where: { body.range(of: $0, options: .regularExpression) != nil }) else { return false }
        let tokens = body.split(whereSeparator: \.isWhitespace)
        // A sentence running on from an equation, as "m = 4, the equation", is not a statement.
        let words = tokens.filter { token in token.allSatisfy(\.isLetter) && token.count >= 3 && isDictionaryWord(String(token)) }
        if words.count >= 2, body.range(of: #"[;{}]\s*$"#, options: .regularExpression) == nil { return false }
        return !tokens.isEmpty && Double(tokens.filter(isWord).count) / Double(tokens.count) < 0.5
    }

    /// Few real words plus at least one mathematical symbol.
    private static func looksLikeMath(_ text: String) -> Bool {
        // Web addresses and paths, as in "sk/~misof/ioi-syllabus/", are not mathematics.
        if text.range(of: #"://|www\.|\w/~|~\w+/"#, options: .regularExpression) != nil { return false }
        // Footnote marks after a name, as in "Aidan N. Gomez∗†", are not mathematics.
        let text = text.replacingOccurrences(of: #"(?<=\p{Lu}\p{Ll}{1,30})[∗†‡§¶]+"#, with: "", options: .regularExpression)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty, text.unicodeScalars.contains(where: isMathSymbol) else { return false }
        // Names of quantities, as "xk" in "xk mod m = 1", and operators such as "mod" are no words.
        let words = tokens.filter { token in
            let letters = wordLetters(token).lowercased()
            return isWord(token) && !mathWords.contains(letters) && (letters.count >= 3 && isDictionaryWord(letters) || shortWords.contains(letters) || letters.count >= 8)
        }
        return Double(words.count) / Double(tokens.count) < 0.4
    }

    /// A row of array cells or table entries, such as `1 3 6 2 8 2 5 9` or `X X X X`.
    private static func isDataRow(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // Three figures in a row, as "0 0 1" in a table of values, are a row too.
        return tokens.count >= 4 && tokens.allSatisfy { $0.count <= 3 && $0.range(of: #"\p{L}{2,}"#, options: .regularExpression) == nil }
            || tokens.count == 3 && tokens.allSatisfy { $0.count <= 3 && $0.allSatisfy(\.isNumber) }
            // So are figures after a name, as "John 10 15" or "103 0.001000 1.000000".
            // A matrix's short rows, as "1 4", stay with their display.
            || text.range(of: #"^(\p{Lu}\p{Ll}{1,12}\s+)?(\d+(\.\d+)?\s+)+\d+(\.\d+)?$"#, options: .regularExpression) != nil
                // Axis ticks and years, as "1999 2000 2001", are labels of a chart.
                && (tokens.first?.first?.isLetter == true || tokens.count == 2 && tokens.contains { $0.count >= 4 }
                    || tokens.contains { $0.range(of: #"\.\d{3,}$"#, options: .regularExpression) != nil })
    }

    private static func isWord(_ token: Substring) -> Bool {
        token.range(of: #"^[(\[“"']?\p{L}\p{Ll}+[)\]”"'.,;:!?]*$"#, options: .regularExpression) != nil
    }

    /// Keeps formulas that stand on their own row: math sharing a row with prose is inline
    /// and stays in the text, while a row ending in an equation number is always a formula.
    private static let mathWords: Set<String> = [
        "mod", "log", "logk", "min", "max", "sin", "cos", "tan", "exp", "lim", "sup", "inf", "arg", "argmin", "argmax",
        "gcd", "lcm", "det", "deg", "dim", "rank", "ker", "floor", "ceil", "sum", "prod", "var", "cov",
        "inv", "gen", "ctx", "val", "mock", "tr", "reg", "kl", "diag", "softmax", "tanh"
    ]

    /// A display set as pieces, as "C[j,i]" over "A⁻¹[i,j] =" and "det(A).", is short lines
    /// centred between the margins, close together, without words, one of them with a sign of
    /// mathematics; PDFKit can leave all of them as text.
    private static func confirmCentredDisplays(in lines: inout [Line]) {
        let prose = lines.filter { $0.kind == nil && $0.text.count >= 40 }.map(\.bounds)
        guard prose.count >= 3 else { return }
        let left = prose.map(\.minX).sorted()[prose.count / 2], right = prose.map(\.maxX).sorted()[prose.count / 2]
        let height = typicalLineHeight(lines.map(\.bounds))
        func piece(_ line: Line) -> Bool {
            let tokens = line.text.split(whereSeparator: \.isWhitespace)
            // An index set small under a sign, as the "A⊂S" under "Σ", is a piece too.
            return (line.kind == nil || line.kind == .formula) && (!line.small || line.text.count <= 6) && !line.heading && !tokens.isEmpty && tokens.count <= 6
                && line.bounds.minX > left + 40 && line.bounds.maxX < right - 40
                && !tokens.contains { token in
                    // A name indexed or applied, as "value[A]" or "sum(S)", is no word.
                    let letters = wordLetters(token).lowercased()
                    return letters.count >= 3 && !mathWords.contains(letters) && isDictionaryWord(letters) && token.range(of: #"^\p{L}+[\[(]"#, options: .regularExpression) == nil
                }
        }
        let candidates = lines.indices.filter { piece(lines[$0]) }
        var seen: Set<Int> = []
        for start in candidates where !seen.contains(start) {
            // The cluster: pieces whose boxes come within half a line of one another.
            var cluster = [start], frontier = [start]
            while let current = frontier.popLast() {
                for other in candidates where !cluster.contains(other) {
                    let a = lines[current].bounds.insetBy(dx: -6, dy: -height * 0.5), b = lines[other].bounds
                    if a.intersects(b) { cluster.append(other); frontier.append(other) }
                }
            }
            seen.formUnion(cluster)
            // An operator, not a footnote's mark as the "∗" after an author's name.
            guard cluster.count >= 2, cluster.contains(where: { lines[$0].text.range(of: #"[=≤≥≠≈<>+−×÷/∑∏∫√∈∪∩]"#, options: .regularExpression) != nil }),
                  !cluster.contains(where: { lines[$0].text.contains("@") }) else { continue }
            // Nothing else stands beside it on its rows: a display is set off from the text.
            let span = cluster.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
            guard !lines.indices.contains(where: { !cluster.contains($0) && !lines[$0].text.isEmpty && lines[$0].bounds.intersects(span.insetBy(dx: -4, dy: 1)) }) else { continue }
            for index in cluster { lines[index].kind = .formula }
        }
    }

    private static func confirmDisplayFormulas(in lines: inout [Line]) {
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
            min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5
        }
        let numbered = lines.filter { $0.text.range(of: #"^\(\d+[a-z]?\)$"#, options: .regularExpression) != nil }.map(\.bounds)
        // Code that continues a sentence on the same row is inline code, read as words.
        let sentences = lines.filter { $0.kind == nil && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 4 }.map(\.bounds)
        for index in lines.indices where lines[index].kind == .code {
            let bounds = lines[index].bounds
            if sentences.contains(where: { sameRow($0, bounds) && max($0.minX, bounds.minX) - min($0.maxX, bounds.maxX) < 12 }) {
                lines[index].kind = nil
            }
        }
        // Plain words of three or more letters, counted even when glued to brackets, as in "]and".
        // Function names such as "mod", "log" or "count(", and arrays such as "value[", belong to the formula.
        // Two-letter joining words such as "to", "is" and "of" count when they stand on their own.
        func plainWords(_ text: String) -> Int {
            guard let pattern = try? NSRegularExpression(pattern: #"[A-Za-z]*[a-z]{3,}(?![A-Za-z\d]*[(\[])|(?<![\p{L}\d])(?:to|is|of|in|or|as|by|at|on|so|be)(?![\p{L}\d(\[])"#) else { return 0 }
            let source = text as NSString
            // Names such as "pos" or "dmodel" in "PE(pos,2i) = sin(pos/100002i/dmodel)" are not words.
            let words = pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).filter { match in
                let word = source.substring(with: match.range)
                // A function name followed by a word, as "sum" in "whose sum is 520", is a word.
                let next = source.substring(from: NSMaxRange(match.range))
                let named = mathWords.contains(word.lowercased()) && next.range(of: #"^ ?\p{Ll}{2,}"#, options: .regularExpression) == nil
                return !named && (word.count >= 8 || isDictionaryWord(word))
            }.count
            // A cross-reference such as "(Equation 8.15)" only appears in sentences.
            let reference = text.range(of: #"\((Equation|Eq\.|Figure|Fig\.|Table|Section|Chapter|Theorem|Lemma|Proposition|Corollary|Definition|Assumption|Example|Remark|Appendix|Algorithm|Listing)\s*[\dA-Z]"#, options: .regularExpression) != nil
            return words + (reference ? 2 : 0)
        }
        // Lines that turn out to be prose can make their neighbours prose too, so this repeats.
        var demoted = true
        while demoted {
            demoted = false
            let prose = lines.filter { $0.kind == nil && !isFragment($0.text) }
            for index in lines.indices where lines[index].kind == .formula {
                let bounds = lines[index].bounds
                // A label set under the term it names lies within it, not beside it.
                let besideProse = prose.contains { line in
                    let box = line.bounds
                    let under = braceLabel(line.text) && min(box.maxX, bounds.maxX) - max(box.minX, bounds.minX) >= box.width * 0.5
                    return !under && sameRow(box, bounds) && max(box.minX, bounds.minX) - min(box.maxX, bounds.maxX) < 16
                }
                // A sentence full of inline math, such as "Proof. Assuming 𝑌 ⊥ 𝑇, we will prove",
                // is read as words; display formulas hold one or two words at most.
                let text = lines[index].text
                let numbered = text.range(of: #"\(\d+(\.\d+)*[a-z]?( revisited)?\)$"#, options: .regularExpression) != nil
                // Without an equation number, a line that ends a sentence with a word, as in
                // "…], respectively.", or carries a longer word, as in "(Sections 7.2 to 7.4) or
                // by modeling", is the tail or middle of a sentence.
                let sentenceEnd = text.range(of: #"[a-z]{4,}[.?!]$"#, options: .regularExpression) != nil
                let longWord = text.matches(of: /[A-Za-z]*[a-z]{6,}(?![A-Za-z\d]*\()/).contains { match in
                    match.output.count >= 10 || isDictionaryWord(String(match.output))
                }
                let sentence = !numbered && (sentenceEnd || (plainWords(text) >= 2 && longWord))
                // A long run of lowercase letters is words, never mathematics.
                let letterRun = text.range(of: #"\p{Ll}{12,}"#, options: .regularExpression) != nil
                if besideProse || plainWords(text) >= 3 || sentence || letterRun {
                    lines[index].kind = nil
                    demoted = true
                }
            }
        }
        let proseLines = lines.filter { $0.kind == nil && !isFragment($0.text) }.map(\.bounds)
        for index in lines.indices where lines[index].kind != .code {
            let bounds = lines[index].bounds
            // The line above can open a paragraph, indented, as "For example, …" over "node 7 is 4+5+5=14:".
            if lines[index].kind == .formula, proseLines.contains(where: { bounds.minX < $0.minX + 2 && bounds.minX > $0.minX - 20
                      && bounds.maxY < $0.minY + 2 && $0.minY - bounds.maxY < bounds.height }) {
                // Display formulas are centred; a mathy line flush with the paragraph above ends a sentence.
                lines[index].kind = nil
            } else if lines[index].kind == nil, lines[index].text.range(of: #"\(\d+(\.\d+)*\)$"#, options: .regularExpression) != nil,
                      lines[index].text.unicodeScalars.contains(where: isMathSymbol),
                      lines[index].text.split(whereSeparator: \.isWhitespace).filter(isWord).count < 2 {
                // Math that ends in its own equation number, such as "𝜇0(𝑤𝑖) (7.12)", is displayed.
                lines[index].kind = .formula
            } else if lines[index].kind == nil, numbered.contains(where: { sameRow($0, bounds) && $0 != bounds }) {
                let tokens = lines[index].text.split(whereSeparator: \.isWhitespace)
                if Double(tokens.filter(isWord).count) / Double(tokens.count) < 0.6 { lines[index].kind = .formula }
            }
        }
    }

    /// Mathematics a keyboard cannot type, such as Greek letters, ∑ or 𝑋, unlike `=` or `<`
    /// which program text uses all the time.
    private static func isTypesetMath(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && isMathSymbol(scalar)
    }

    private static func isMathSymbol(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .mathSymbol { return true }
        switch scalar.value {
        case 0x0391...0x03C9, 0x2190...0x21FF, 0x2200...0x22FF, 0x27C0...0x27FF, 0x2980...0x2AFF, 0x1D400...0x1D7FF:
            return true
        default:
            return false
        }
    }

    // MARK: Regions

    /// Groups neighbouring formula or code lines, then pulls in fragments such as
    /// subscripts, denominators and equation numbers that sit inside a group.
    private static func textBlocks(in lines: inout [Line]) -> [Block] {
        var blocks: [Block] = []
        for index in lines.indices {
            guard let kind = lines[index].kind else { continue }
            let bounds = lines[index].bounds
            let rect = blocks.last?.rect ?? .null
            let gap = max(rect.minY, bounds.minY) - min(rect.maxY, bounds.maxY)
            let sideGap = max(rect.minX, bounds.minX) - min(rect.maxX, bounds.maxX)
            // The next line of a block sits just below it in the same column.
            if let last = blocks.indices.last, blocks[last].kind == kind, index > 0, lines[index - 1].block == last,
               gap < max(bounds.height, 8) * 1.2, sideGap < 12 {
                blocks[last].rect = blocks[last].rect.union(bounds)
                lines[index].block = last
            } else {
                blocks.append(Block(kind: kind, rect: bounds, firstLine: index))
                lines[index].block = blocks.count - 1
            }
        }

        for index in lines.indices where lines[index].block == nil && isFragment(lines[index].text) {
            let bounds = lines[index].bounds
            let reach = min(max(bounds.height, 8), 14) * 0.8
            // Sideways gaps count too, so an equation number joins its equation, not a margin note beside it.
            func distance(_ rect: CGRect) -> CGFloat {
                max(max(0, max(rect.minY, bounds.minY) - min(rect.maxY, bounds.maxY)),
                    max(0, max(rect.minX, bounds.minX) - min(rect.maxX, bounds.maxX)))
            }
            if let block = blocks.indices
                .filter({ blocks[$0].rect.insetBy(dx: -40, dy: -reach).intersects(bounds) })
                .min(by: { distance(blocks[$0].rect) < distance(blocks[$1].rect) }) {
                blocks[block].rect = blocks[block].rect.union(bounds)
                lines[index].block = block
                blocks[block].firstLine = min(blocks[block].firstLine ?? index, index)
            }
        }

        mergeNeighbours(&blocks, lines: &lines, acrossKinds: false)

        // Short lines inside a listing, such as `return value`, can look proportional.
        for index in lines.indices where lines[index].block == nil && lines[index].text.count < 40 {
            let bounds = lines[index].bounds
            if let block = blocks.indices.first(where: { blocks[$0].kind == .code && !blocks[$0].rect.isNull
                && bounds.minX >= blocks[$0].rect.minX - 1 && blocks[$0].rect.minY - bounds.maxY < max(bounds.height, 8) * 0.8
                && bounds.minY < blocks[$0].rect.minY }), index > 0, lines[index - 1].block == block {
                blocks[block].rect = blocks[block].rect.union(bounds)
                lines[index].block = block
            }
        }

        // A lone short code-font line is usually an identifier inside prose, not a listing.
        for block in blocks.indices.reversed() {
            let members = lines.indices.filter { lines[$0].block == block }
            let length = members.reduce(0) { $0 + lines[$1].text.count }
            if blocks[block].kind == .code, members.count == 1, length < 16 || lines[members[0]].text.contains("://") {
                for member in members { lines[member].block = nil }
                blocks[block].rect = .null
                blocks[block].firstLine = nil
            }
        }
        return compacted(blocks, lines: &lines)
    }

    /// Joins blocks that touch vertically, such as the pieces of one multi-line formula or a
    /// listing and the shaded box drawn behind it.
    private static func mergeNeighbours(_ blocks: inout [Block], lines: inout [Line], acrossKinds: Bool) {
        // The right edge of the main text column, from where full prose lines end.
        let proseEnds = lines.filter { $0.kind == nil && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 5 }
            .map(\.bounds.maxX).sorted()
        let columnEdge = proseEnds.isEmpty ? CGFloat.infinity : proseEnds[proseEnds.count / 2] + 6
        var merged = true
        while merged {
            merged = false
            outer: for first in blocks.indices where !blocks[first].rect.isNull {
                for second in blocks.indices where second > first && !blocks[second].rect.isNull
                    && (acrossKinds || blocks[second].kind == blocks[first].kind) {
                    let a = blocks[first].rect, b = blocks[second].rect
                    let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                    let sideGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    // Side by side they must nearly touch, and stacked they must overlap, so an
                    // equation in the text column never joins a drawing in the margin beside it.
                    // Parts of one equation on a row can sit further apart, as long as both stay
                    // on the same side of the text column's edge.
                    let sameColumn = (a.midX < columnEdge) == (b.midX < columnEdge)
                    let rowReach: CGFloat = blocks[first].kind == .formula && blocks[second].kind == .formula && sameColumn ? 60 : 8
                    guard gap < 12, gap < 0 ? sideGap < rowReach : sideGap < 0 else { continue }
                    let between = CGRect(x: min(a.minX, b.minX), y: min(a.maxY, b.maxY), width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: max(gap, 0))
                    let proseBetween = lines.contains { $0.block == nil && !isFragment($0.text) && between.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
                    guard !proseBetween else { continue }
                    if blocks[first].kind != blocks[second].kind {
                        // Code wins, since its shading is what reads as a drawing.
                        let kinds = [blocks[first].kind, blocks[second].kind]
                        blocks[first].kind = kinds.contains(.code) ? .code : (a.width * a.height >= b.width * b.height ? kinds[0] : kinds[1])
                    }
                    blocks[first].rect = a.union(b)
                    blocks[first].firstLine = [blocks[first].firstLine, blocks[second].firstLine].compactMap { $0 }.min()
                    blocks[second].rect = .null
                    blocks[second].firstLine = nil
                    for line in lines.indices where lines[line].block == second { lines[line].block = first }
                    merged = true
                    break outer
                }
            }
        }
    }

    private static func compacted(_ blocks: [Block], lines: inout [Line]) -> [Block] {
        var mapping: [Int: Int] = [:]
        var result: [Block] = []
        for (index, block) in blocks.enumerated() where !block.rect.isNull {
            mapping[index] = result.count
            result.append(block)
        }
        for index in lines.indices {
            lines[index].block = lines[index].block.flatMap { mapping[$0] }
        }
        return result
    }

    /// Drawings standing side by side at the same height, as the three columns of solutions in
    /// "Boxes and balls", with nothing to read between them, are one picture.
    private static func joinSideBySide(_ blocks: inout [Block], lines: inout [Line]) {
        var changed = true
        while changed {
            changed = false
            outer: for first in blocks.indices where blocks[first].kind == .image && !blocks[first].rect.isNull {
                for second in blocks.indices where second != first && blocks[second].kind == .image && !blocks[second].rect.isNull {
                    let a = blocks[first].rect, b = blocks[second].rect
                    let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    guard shared >= min(a.height, b.height) * 0.8, gap >= 0, gap < 60 else { continue }
                    let between = CGRect(x: min(a.maxX, b.maxX), y: max(a.minY, b.minY), width: gap, height: shared)
                    guard !lines.contains(where: { $0.block == nil && $0.bounds.intersects(between) && $0.bounds.midY > between.minY && $0.bounds.midY < between.maxY
                        && $0.text.split(whereSeparator: \.isWhitespace).contains(where: isWord) }) else { continue }
                    blocks[first].rect = a.union(b)
                    blocks[first].firstLine = [blocks[first].firstLine, blocks[second].firstLine].compactMap { $0 }.min()
                    for index in lines.indices where lines[index].block == second { lines[index].block = first }
                    blocks[second].rect = .null
                    blocks[second].firstLine = nil
                    changed = true
                    break outer
                }
            }
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// A table drawn as rows of figures, as "John 10 15", takes the row of headings just over it,
    /// as "person arrival time leaving time".
    /// A table of notations, as "intersection a ∩ b a & b" over "union a ∪ b a | b", comes as
    /// short rows that start at one edge and hold operators, under a heading row such as "set
    /// syntax bit syntax". PDFKit makes some rows formulas and leaves others as text; the table is
    /// one picture.
    private static func gatherOperatorTables(_ blocks: inout [Block], lines: inout [Line]) {
        let height = typicalLineHeight(lines.map(\.bounds))
        let body = lines.filter { $0.text.count >= 40 }.map(\.bounds.width).max() ?? 0
        guard body > 0 else { return }
        func operators(_ text: String) -> Bool { text.range(of: #"[∩∪¯~&|\\⊕∧∨¬⊆⊂∈]"#, options: .regularExpression) != nil }
        func free(_ index: Int) -> Bool { lines[index].block == nil || blocks[lines[index].block!].kind == .formula }
        let order = lines.indices.filter { !lines[$0].text.isEmpty && !lines[$0].small && !lines[$0].heading }.sorted { lines[$0].bounds.maxY > lines[$1].bounds.maxY }
        var position = 0
        while position < order.count {
            let first = order[position]
            var rows = [first]
            var next = position + 1
            while next < order.count, free(order[next]) {
                let candidate = lines[order[next]].bounds, last = lines[rows.last!].bounds
                guard last.minY - candidate.maxY < height * 0.8 else { break }
                rows.append(order[next])
                next += 1
            }
            let starts = rows.filter { abs(lines[$0].bounds.minX - lines[first].bounds.minX) <= 3 }
            let short = rows.allSatisfy { lines[$0].bounds.width <= body * 0.6 && lines[$0].text.split(whereSeparator: \.isWhitespace).count <= 8 }
            guard free(first), rows.count >= 3, starts.count >= 3, short, rows.filter({ operators(lines[$0].text) }).count >= 3,
                  rows.allSatisfy({ lines[$0].text.range(of: #"[.:;?!]$"#, options: .regularExpression) == nil }) else { position += 1; continue }
            // Each row starts with the name of what it shows, as "union", and the heading row above
            // names the columns, right of those names.
            let named = starts.allSatisfy { row in
                lines[row].text.split(whereSeparator: \.isWhitespace).first.map { $0.count >= 3 && isDictionaryWord(wordLetters($0).lowercased()) } == true
            }
            guard named, position > 0, let header = Optional(order[position - 1]), free(header), lines[header].bounds.minY - lines[first].bounds.maxY < height * 0.8,
                  lines[header].bounds.minX > lines[first].bounds.minX + 10, lines[header].text.range(of: #"[.:;?!]$"#, options: .regularExpression) == nil else { position += 1; continue }
            let members = [header] + rows
            let rect = members.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
            for member in members {
                if let old = lines[member].block, !lines.indices.contains(where: { $0 != member && !members.contains($0) && lines[$0].block == old }) { blocks[old].rect = .null }
                lines[member].block = blocks.count
            }
            blocks.append(Block(kind: .table, rect: rect, firstLine: members.min()))
            position = next
        }
    }

    /// A list of values set in two columns, as "• value[{0}] = 1" beside "• value[{0,2}] = 1",
    /// comes as two formulas of aligned rows; it is one picture, with any row PDFKit left as text.
    private static func mergeFormulaColumns(_ blocks: inout [Block], lines: inout [Line]) {
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5 }
        for first in blocks.indices where blocks[first].kind == .formula && !blocks[first].rect.isNull {
            for second in blocks.indices where second != first && blocks[second].kind == .formula && !blocks[second].rect.isNull {
                let left = lines.indices.filter { lines[$0].block == first }, right = lines.indices.filter { lines[$0].block == second }
                // Columns of one list are set alike; a note's formula in the margin beside a display is not.
                let widths = [blocks[first].rect.width, blocks[second].rect.width]
                guard left.count >= 3, right.count >= 3, blocks[first].rect.maxX < blocks[second].rect.minX, blocks[second].rect.minX - blocks[first].rect.maxX < 150,
                      widths.min()! * 2 >= widths.max()!, !(left + right).contains(where: { lines[$0].small }) else { continue }
                let paired = left.filter { l in right.contains { sameRow(lines[l].bounds, lines[$0].bounds) } }
                guard paired.count * 10 >= min(left.count, right.count) * 8 else { continue }
                for index in right { lines[index].block = first }
                var rect = blocks[first].rect.union(blocks[second].rect)
                blocks[second].rect = .null
                // A row of the list PDFKit left as text, as "• value[ ] = 3", goes with it.
                for index in lines.indices where lines[index].block == nil && rect.insetBy(dx: -4, dy: -14).contains(CGPoint(x: lines[index].bounds.midX, y: lines[index].bounds.midY))
                    && lines[index].text.count <= 30 && abs(lines[index].bounds.minX - rect.minX) < 4
                    && !lines[index].text.split(whereSeparator: \.isWhitespace).contains(where: { $0.count >= 3 && isDictionaryWord(wordLetters($0).lowercased()) && $0.range(of: #"^\p{L}+[\[(]"#, options: .regularExpression) == nil }) {
                    lines[index].block = first
                    rect = rect.union(lines[index].bounds)
                }
                blocks[first].rect = rect
                blocks[first].firstLine = lines.indices.first { lines[$0].block == first }
            }
        }
    }

    /// A drawing's labels set in a row under or over it, as "illegal illegal illegal valid" under
    /// four boards or "step 1 step 2 step 3" under three trees, are spread far wider than prose and
    /// belong to it; a heading that the drawing's box reached, as "Method 2", does not.
    private static func settleFigureLabels(_ blocks: inout [Block], lines: inout [Line]) {
        let height = typicalLineHeight(lines.map(\.bounds))
        let prose = lines.filter { $0.block == nil && $0.text.count >= 40 }.map { $0.bounds.width / CGFloat($0.text.count) }.sorted()
        guard !prose.isEmpty else { return }
        let pitch = prose[prose.count / 2]
        for block in blocks.indices where blocks[block].kind == .image && !blocks[block].rect.isNull {
            for index in lines.indices where lines[index].heading && (lines[index].block == block || lines[index].bounds.intersects(blocks[block].rect)) {
                lines[index].block = nil
                var rect = blocks[block].rect
                let bounds = lines[index].bounds
                if bounds.midY < rect.midY { let top = rect.maxY; rect.origin.y = bounds.maxY + 0.5; rect.size.height = top - rect.minY }
                else { rect.size.height = bounds.minY - 0.5 - rect.minY }
                if rect.height > 4 { blocks[block].rect = rect }
            }
            // A row of results under the drawings, as "a × b = 6  a × b = 0  a × b = −8", that
            // PDFKit made a formula of its own, is their caption row.
            // A display taken as a picture, whose labels hold "=", is no drawing to caption.
            let drawing = !lines.contains { $0.block == block && $0.text.contains("=") }
            for other in blocks.indices where drawing && other != block && blocks[other].kind == .formula && !blocks[other].rect.isNull {
                let rect = blocks[block].rect, row = blocks[other].rect
                let members = lines.indices.filter { lines[$0].block == other }
                let gap = row.maxY < rect.midY ? rect.minY - row.maxY : row.minY - rect.maxY
                guard !members.isEmpty, gap >= -1, gap < height * 1.5, row.minX >= rect.minX - 30, row.maxX <= rect.maxX + 30, row.width >= rect.width * 0.6,
                      members.count >= 2 || members.allSatisfy({ lines[$0].text.split(whereSeparator: \.isWhitespace).count >= 6 }),
                      members.allSatisfy({ min(lines[$0].bounds.maxY, row.maxY) - max(lines[$0].bounds.minY, row.minY) >= lines[$0].bounds.height * 0.5 }),
                      row.height <= height * 1.6,
                      !members.contains(where: { lines[$0].text.split(whereSeparator: \.isWhitespace).contains { $0.count >= 3 && isDictionaryWord(wordLetters($0).lowercased()) } }) else { continue }
                for member in members { lines[member].block = block }
                blocks[block].rect = rect.union(row)
                blocks[other].rect = .null
            }
            // A node standing apart beside the drawing, as the "5" over "A" left of a Huffman tree,
            // is part of it: a label of a few characters within the drawing's height.
            for index in lines.indices where lines[index].block == nil && !lines[index].text.isEmpty && lines[index].text.count <= 3 && !lines[index].small {
                let bounds = lines[index].bounds, rect = blocks[block].rect
                let gap = bounds.maxX < rect.minX ? rect.minX - bounds.maxX : bounds.minX - rect.maxX
                guard bounds.midY > rect.minY, bounds.midY < rect.maxY, gap > 0, gap < 60,
                      !lines.indices.contains(where: { $0 != index && lines[$0].block != block && !lines[$0].text.isEmpty
                        && lines[$0].bounds.intersects(CGRect(x: min(bounds.maxX, rect.maxX), y: bounds.minY, width: gap, height: bounds.height)) && lines[$0].text.count > 3 }) else { continue }
                lines[index].block = block
                blocks[block].rect = rect.union(bounds)
            }
            for index in lines.indices where lines[index].block == nil && !lines[index].heading && !lines[index].text.isEmpty {
                let bounds = lines[index].bounds, rect = blocks[block].rect
                let tokens = lines[index].text.split(whereSeparator: \.isWhitespace)
                let gap = bounds.maxY < rect.midY ? rect.minY - bounds.maxY : bounds.minY - rect.maxY
                guard (2...8).contains(tokens.count), gap >= -1, gap < height, bounds.minX >= rect.minX - 10, bounds.maxX <= rect.maxX + 10,
                      bounds.width / CGFloat(lines[index].text.count) >= pitch * 1.6,
                      lines[index].text.range(of: #"[.:;,?!]$"#, options: .regularExpression) == nil else { continue }
                lines[index].block = block
                blocks[block].rect = rect.union(bounds)
            }
        }
    }

    /// A row of a display that PDFKit set apart from it, as the "gcd(b,a mod b)" case inside a
    /// definition by cases, or the last of aligned equations just under the rest, as "xⁿ mod m =
    /// (x mod m)ⁿ mod m", belongs to that display.
    private static func absorbEnclosedRows(_ blocks: inout [Block], lines: inout [Line]) {
        let height = typicalLineHeight(lines.map(\.bounds))
        var changed = true
        while changed {
            changed = false
            // A short row PDFKit made a block of its own, as the "x=1" under a sum, counts too.
            func alone(_ index: Int) -> Bool {
                guard let own = lines[index].block else { return true }
                return blocks[own].kind != .image && lines[index].text.count <= 8 && !lines.indices.contains { $0 != index && lines[$0].block == own }
            }
            // A limit set small under a sum is no footnote.
            for index in lines.indices where alone(index) && (!lines[index].small || lines[index].text.count <= 8) {
                let bounds = lines[index].bounds
                let tokens = lines[index].text.split(whereSeparator: \.isWhitespace)
                // Prose has words; a row of mathematics only names and the words of a case, as "mod"
                // or "n is even".
                let cases: Set<String> = ["if", "is", "odd", "even", "otherwise", "and", "for", "all", "else", "true", "false"]
                guard !tokens.isEmpty, tokens.first?.first?.isUppercase != true || tokens.count == 1, tokens.allSatisfy({ token in
                    let letters = wordLetters(token).lowercased()
                    return !isWord(token) || letters.count < 3 || mathWords.contains(letters) || cases.contains(letters) || !isDictionaryWord(letters)
                }) else { continue }
                for block in blocks.indices where blocks[block].kind == .formula && !blocks[block].rect.isNull && block != lines[index].block {
                    let rect = blocks[block].rect
                    let inside = bounds.intersection(rect)
                    let enclosed = !inside.isNull && inside.width * inside.height >= bounds.width * bounds.height * 0.8
                    // A row under the display stays within its width, which prose set from the margin does not.
                    // A piece of a sentence's row, as the "ζ̄ = …" of "Finally, for ζ̄ = … is an average",
                    // stays with the sentence.
                    let sentenceRow = lines.indices.contains { other in
                        other != index && lines[other].block == nil
                            && min(lines[other].bounds.maxY, bounds.maxY) - max(lines[other].bounds.minY, bounds.minY) > min(lines[other].bounds.height, bounds.height) * 0.5
                            && lines[other].text.split(whereSeparator: \.isWhitespace).contains { token in
                                let letters = wordLetters(token).lowercased()
                                return letters.count >= 3 && !mathWords.contains(letters) && isDictionaryWord(letters)
                            }
                    }
                    let under = bounds.minY < rect.minY && bounds.maxY > rect.minY - height * 0.6
                        && bounds.minX >= rect.minX - 24 && bounds.maxX <= rect.maxX + 12
                        // An equation, or the next row of a table of values ending where the row above does.
                        && (lines[index].text.contains("=") && bounds.minX >= rect.minX - 12 || tokens.count >= 5 && abs(bounds.maxX - rect.maxX) < 6)
                    guard enclosed || under, !sentenceRow else { continue }
                    if let own = lines[index].block { blocks[own].rect = .null }
                    lines[index].block = block
                    lines[index].kind = .formula
                    blocks[block].rect = rect.union(bounds)
                    changed = true
                    break
                }
            }
        }
    }

    private static func attachTableHeaders(_ blocks: inout [Block], lines: inout [Line]) {
        // A row of a table of timings, as "10⁴ > 10.0 s 0.1 s 0.0 s", is figures and units.
        // A cell of such a row holds a figure, a unit or a sign, as "s", ">" or "·"; a short row of
        // a formula's table, as "g(n− 1) 2", names and counts.
        func figures(_ text: String) -> Bool {
            let tokens = text.split(whereSeparator: \.isWhitespace)
            guard !tokens.contains(where: { $0.count >= 4 && isDictionaryWord(wordLetters($0).lowercased()) }) else { return false }
            let cells = tokens.filter { $0.contains(where: \.isNumber) || $0.count <= 2 }.count
            return tokens.count >= 3 && cells == tokens.count && tokens.filter { $0.contains(where: \.isNumber) }.count >= 2 || tokens.count <= 3
        }
        for index in blocks.indices where (blocks[index].kind == .image || blocks[index].kind == .formula) && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }
            let numbered = members.filter { lines[$0].text.contains(where: \.isNumber) }.count * 2 >= members.count
            guard members.count >= 2, numbered,
                  members.allSatisfy({ isDataRow(lines[$0].text) || figures(lines[$0].text) || blocks[index].kind == .image && lines[$0].text.split(whereSeparator: \.isWhitespace).count <= 2 }) else { continue }
            let rect = blocks[index].rect
            let rowHeight = members.map { lines[$0].bounds.height }.min() ?? 10
            guard let header = lines.indices.filter({ index in
                let line = lines[index]
                return line.block == nil && !line.heading && line.bounds.minY >= rect.maxY - 2 && line.bounds.minY - rect.maxY < rowHeight * 1.5
                    && line.bounds.minX >= rect.minX - 60 && line.bounds.maxX <= rect.maxX + 40
                    && line.text.split(whereSeparator: \.isWhitespace).count <= 10 && line.text.range(of: #"[.:;,?!]$"#, options: .regularExpression) == nil
            }).min(by: { lines[$0].bounds.minY < lines[$1].bounds.minY }) else { continue }
            // A formula of two rows takes a row of figures over it, as "10110 (22)" over "& 11010 (26)",
            // not a heading of words.
            // Over more rows, a formula's table takes a heading of words, as "function call number of
            // calls", never a piece of a display.
            let words = lines[header].text.split(whereSeparator: \.isWhitespace).filter { $0.count >= 3 && isDictionaryWord(wordLetters($0).lowercased()) }.count
            if blocks[index].kind == .formula, members.count < 3 ? !figures(lines[header].text) || lines[header].text.contains(where: \.isLetter) && !isDataRow(lines[header].text) : words < 2 { continue }
            lines[header].block = index
            blocks[index].rect = rect.union(lines[header].bounds)
            blocks[index].firstLine = min(blocks[index].firstLine ?? header, header)
        }
    }

    /// The panels of one figure, such as "Population", "Subpopulations", "Conditioning" and
    /// "Intervening" over "Figure 4.2: …", can stand far apart; every drawing between a caption
    /// and the prose above it is part of one picture, with the panel titles among them.
    private static func gatherFigures(_ blocks: inout [Block], lines: inout [Line], ink: InkMap?) {
        func words(_ line: Line) -> Int { line.text.split(whereSeparator: \.isWhitespace).filter(isWord).count }
        let pattern = #"^(Figure|Fig\.)\s*\d+(\.\d+)*[a-z]?\s*[:.]"#
        let captions = lines.indices.filter { lines[$0].block == nil && lines[$0].text.range(of: pattern, options: .regularExpression) != nil }
        // A drawing that took in a caption of its own is another figure.
        func captioned(_ block: Int) -> Bool { lines.contains { $0.block == block && $0.text.range(of: pattern, options: .regularExpression) != nil } }
        var changed = false
        for caption in captions {
            let below = lines[caption].bounds
            // Drawings above the caption, nearest first.
            let above = blocks.indices.filter { blocks[$0].kind == .image && !blocks[$0].rect.isNull && blocks[$0].rect.minY >= below.maxY - 2 }
                .sorted { blocks[$0].rect.minY < blocks[$1].rect.minY }
            guard let first = above.first, blocks[first].rect.minY - below.maxY < 40, !captioned(first) else { continue }
            var region = blocks[first].rect
            var members = [first]
            for other in above.dropFirst() {
                let union = region.union(blocks[other].rect)
                // Prose or another caption between them means another figure.
                let parted = lines.indices.contains { index in
                    let line = lines[index]
                    guard line.block == nil, index != caption, line.bounds.minX < union.maxX, line.bounds.maxX > union.minX,
                          line.bounds.midY > below.maxY, line.bounds.midY < union.maxY else { return false }
                    let inside = region.insetBy(dx: -2, dy: -2).contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY))
                        || blocks[other].rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY))
                    return !inside && (words(line) >= 4 || captions.contains(index))
                }
                if parted || captioned(other) { break }
                region = union
                members.append(other)
            }
            // Panel titles in a row just over the drawings, as "Scaled Dot-Product Attention" and
            // "Multi-Head Attention" over Figure 2.
            for index in lines.indices where lines[index].block == nil && index != caption {
                let title = lines[index]
                let tokens = title.text.split(whereSeparator: \.isWhitespace)
                guard title.bounds.minY >= region.maxY - 2, title.bounds.minY - region.maxY < 18,
                      title.bounds.minX >= region.minX - 40, title.bounds.maxX <= region.maxX + 40, words(title) <= 8,
                      title.text.range(of: #"[.:;,?!]$"#, options: .regularExpression) == nil,
                      tokens.allSatisfy({ $0.first.map { !$0.isLetter || $0.isUppercase } ?? true }) else { continue }
                lines[index].block = first
                region = region.union(title.bounds)
                changed = true
            }
            blocks[first].rect = region
            guard members.count > 1 else { continue }
            for other in members.dropFirst() {
                for index in lines.indices where lines[index].block == other { lines[index].block = first }
                blocks[first].firstLine = [blocks[first].firstLine, blocks[other].firstLine].compactMap { $0 }.min()
                blocks[other].rect = .null
                blocks[other].firstLine = nil
            }
            blocks[first].rect = region
            // Panel titles and labels in the gaps between the panels.
            for index in lines.indices where lines[index].block == nil && index != caption && words(lines[index]) <= 3
                && region.insetBy(dx: -2, dy: -2).contains(lines[index].bounds) {
                lines[index].block = first
            }
            changed = true
        }
        if changed { blocks = compacted(blocks, lines: &lines) }
        // A flowchart of boxed labels, as "Causal Estimand → Statistical Estimand → Estimate", is
        // drawn in lines too thin for the search for drawings; its labels stand just above the caption.
        guard let ink else { return }
        for caption in captions where lines[caption].block == nil {
            let below = lines[caption].bounds
            guard !blocks.contains(where: { !$0.rect.isNull && $0.rect.minY >= below.maxY - 2 && $0.rect.minY - below.maxY < 40
                && $0.rect.minX < below.maxX && $0.rect.maxX > below.minX }) else { continue }
            var labels: [Int] = [], floor = below.maxY
            while let next = lines.indices.filter({ !labels.contains($0) && lines[$0].block == nil && lines[$0].bounds.minY >= floor - 2
                && lines[$0].bounds.minY - floor < 24 && lines[$0].bounds.minX < below.maxX && lines[$0].bounds.maxX > below.minX })
                .min(by: { lines[$0].bounds.minY < lines[$1].bounds.minY }) {
                // The end of the paragraph above, as "Figure 2.5.", is no label.
                guard words(lines[next]) <= 3, lines[next].text.range(of: #"[.:;?!]$"#, options: .regularExpression) == nil else { break }
                let row = lines.indices.filter { index in
                    !labels.contains(index) && lines[index].block == nil && words(lines[index]) <= 3
                        && min(lines[index].bounds.maxY, lines[next].bounds.maxY) - max(lines[index].bounds.minY, lines[next].bounds.minY) > 0
                }
                labels += row
                floor = row.map { lines[$0].bounds.maxY }.max() ?? lines[next].bounds.maxY
            }
            guard labels.count >= 2 else { continue }
            let area = labels.reduce(CGRect.null) { $0.union(lines[$1].bounds) }.insetBy(dx: -6, dy: -6)
            // Boxes and arrows: ink that is not lettering.
            guard ink.inkCount(in: area, excluding: lines.map { $0.bounds.insetBy(dx: -1, dy: -1) }) >= 40 else { continue }
            blocks.append(Block(kind: .image, rect: area, firstLine: labels.min()))
            for index in labels { lines[index].block = blocks.count - 1 }
        }
    }

    /// A table set as text under a caption such as "Table 2: …" is one picture: read a line at a
    /// time its cells make no sense. The caption stays in the text.
    private static func gatherTables(_ blocks: inout [Block], lines: inout [Line], page: PDFPage, bounds: CGRect) {
        let lineHeight = typicalLineHeight(lines.map(\.bounds))
        let order = lines.indices.sorted { lines[$0].bounds.maxY > lines[$1].bounds.maxY }
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5 }
        var tables: [(rect: CGRect, body: [Int], caption: [Int], kind: SectionFigure.Kind)] = []
        for start in lines.indices where lines[start].text.range(of: #"^Table \d+[:.]"#, options: .regularExpression) != nil {
            // The caption is a paragraph: a row that is full and has not ended a sentence goes on.
            var row = lines.indices.filter { sameRow(lines[$0].bounds, lines[start].bounds) && lines[$0].bounds.minX >= lines[start].bounds.minX - 2 }
            var caption = row.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
            var captionLines = row
            // Captions in a margin column belong to tables already shown as pictures.
            guard caption.width >= bounds.width * 0.55 else { continue }
            let right = caption.maxX
            while let last = row.max(by: { lines[$0].bounds.maxX < lines[$1].bounds.maxX }), lines[last].bounds.maxX >= right - 15,
                  !lines[last].text.hasSuffix("."),
                  let next = order.first(where: { lines[$0].bounds.maxY < caption.minY + 1 && caption.minY - lines[$0].bounds.maxY < lineHeight }) {
                row = lines.indices.filter { sameRow(lines[$0].bounds, lines[next].bounds) }
                caption = row.reduce(caption) { $0.union(lines[$1].bounds) }
                captionLines += row
            }
            // The table runs down from the caption to the first wide gap or full line of prose.
            var body: [Int] = [], bottom = caption.minY
            for index in order where lines[index].bounds.maxY < caption.minY + 1 && lines[index].bounds.minX < caption.maxX && lines[index].bounds.maxX > caption.minX {
                let line = lines[index]
                if bottom - line.bounds.maxY > lineHeight * (body.isEmpty ? 2.5 : 1.6) { break }
                if line.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 6, line.bounds.width >= caption.width * 0.92 { break }
                body.append(index)
                bottom = min(bottom, line.bounds.minY)
            }
            var rows: [CGRect] = []
            for index in body where !rows.contains(where: { sameRow($0, lines[index].bounds) }) { rows.append(lines[index].bounds) }
            guard rows.count >= 3 else { continue }
            tables.append((body.reduce(CGRect.null) { $0.union(lines[$1].bounds) }, body, captionLines, .table))
        }
        // A table with no caption, such as "character codeword" over "A 00", "B 01", …: three or
        // more short rows set apart from the text, starting and ending at the same places, under a
        // header row.
        let margin = lines.filter { $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 6 }.map(\.bounds.minX).min() ?? bounds.minX
        let measure = lines.map(\.bounds.maxX).max().map { $0 - margin } ?? bounds.width
        // Rows: lines on the same row, left to right, from the top.
        var rows: [[Int]] = []
        // Cells such as "n ≤ 10 O(n!)" can look like formulas.
        for index in order where lines[index].kind != .code && (lines[index].block.map { blocks[$0].kind == .formula } ?? true) {
            // Centres decide rows: line boxes can be far taller than their letters.
            if let last = rows.indices.last, rows[last].contains(where: { abs(lines[$0].bounds.midY - lines[index].bounds.midY) < lineHeight * 0.4 }) {
                rows[last].append(index)
            } else {
                rows.append([index])
            }
        }
        func span(_ row: [Int]) -> CGRect { row.reduce(CGRect.null) { $0.union(lines[$1].bounds) } }
        func cells(_ row: [Int]) -> Bool {
            let tokens = row.flatMap { lines[$0].text.split(whereSeparator: \.isWhitespace) }
            return tokens.count >= 2 && tokens.count <= 6 && tokens.filter { $0.count >= 4 }.count <= 3
        }
        var start = 0
        while start < rows.count {
            guard cells(rows[start]) else { start += 1; continue }
            let first = span(rows[start])
            var run = [rows[start]]
            while start + run.count < rows.count {
                let next = span(rows[start + run.count]), previous = span(run.last!)
                guard abs(next.minX - first.minX) < 2, previous.minY - next.maxY < lineHeight * 0.8, cells(rows[start + run.count]) else { break }
                run.append(rows[start + run.count])
            }
            defer { start += run.count }
            let body = run.flatMap { $0 }
            // Rows of formulas, one line each, are an aligned derivation or a list of values, not a table,
            // and neither is a derivation whose equation numbers stand apart.
            let equations = run.filter { $0.contains { lines[$0].text.contains("=") } }.count * 2 >= run.count
                || body.contains { lines[$0].text.range(of: #"^\([A-Z]?\d+(\.\d+)*\)$"#, options: .regularExpression) != nil }
            // Entries of a contents list, "Interventions … 42", end in page numbers.
            let contents = run.filter { $0.contains { lines[$0].text.range(of: #"[A-Za-z)]{3,}.*\s\d{1,3}$"#, options: .regularExpression) != nil } }.count * 2 >= run.count
            guard run.count >= 3, !equations, !contents, run.contains(where: { $0.count >= 2 || $0.contains { lines[$0].kind == nil && lines[$0].block == nil } }),
                  cells(rows[start]), first.minX > margin + 30, body.allSatisfy({ lines[$0].bounds.maxX - first.minX < measure * 0.5 }),
                  !tables.contains(where: { $0.body.contains(body[0]) }) else { continue }
            var members = body
            // The header sits just above, over the same columns.
            if start > 0 {
                let header = span(rows[start - 1])
                if header.minX > margin + 20, header.width < measure * 0.6, header.minY - first.maxY < lineHeight * 1.2 { members += rows[start - 1] }
            }
            tables.append((members.reduce(CGRect.null) { $0.union(lines[$1].bounds) }, members, [], .table))
        }
        // An algorithm's numbered steps ("1: for j = 1,2 do", "2: Fit …", …) with their comments
        // and the Require/Ensure lines under its caption are one listing; the caption is read.
        let steps = order.filter { lines[$0].text.range(of: #"^\s*\d{1,3}:"#, options: .regularExpression) != nil }
        var runStart = 0
        while runStart < steps.count {
            var run = [steps[runStart]]
            func number(_ index: Int) -> Int { Int(lines[index].text.prefix { $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)) ?? -1 }
            while runStart + run.count < steps.count {
                let next = steps[runStart + run.count]
                guard number(next) > number(run.last!), number(next) <= number(run.last!) + 2,
                      lines[run.last!].bounds.minY - lines[next].bounds.maxY < lineHeight * 3 else { break }
                run.append(next)
            }
            defer { runStart += run.count }
            guard run.count >= 4, !tables.contains(where: { $0.body.contains(run[0]) }) else { continue }
            let left = run.map { lines[$0].bounds.minX }.min()! - 6
            var top = lines[run[0]].bounds.maxY, bottom = run.map { lines[$0].bounds.minY }.min()!
            // Up to the caption, such as "Algorithm 1 ADIGen-PO: …".
            let above = order.filter { lines[$0].bounds.midY > top && lines[$0].bounds.minY - top < lineHeight * 8 && lines[$0].bounds.maxX > left }
            if let caption = above.last(where: { lines[$0].text.range(of: #"^Algorithm\s+\d"#, options: .regularExpression) != nil }) {
                let captionBottom = lines.indices.filter { sameRow(lines[$0].bounds, lines[caption].bounds) || (lines[$0].bounds.maxY <= lines[caption].bounds.minY + 1
                    && lines[caption].bounds.minY - lines[$0].bounds.maxY < lineHeight * 0.5 && lines[$0].text.range(of: #"^(Require|Ensure|Input|Output)"#, options: .regularExpression) == nil
                    && lines[$0].bounds.midY > top) }.map { lines[$0].bounds.minY }.min() ?? lines[caption].bounds.minY
                top = captionBottom - 0.5
            }
            // Down through lines that carry on the last step.
            for index in order where lines[index].bounds.maxY < bottom + 1 && lines[index].bounds.minX >= left {
                guard bottom - lines[index].bounds.maxY < lineHeight * 0.8 else { break }
                bottom = min(bottom, lines[index].bounds.minY)
            }
            let body = lines.indices.filter { lines[$0].bounds.midY < top && lines[$0].bounds.midY > bottom - 1 && lines[$0].bounds.minX >= left }
            tables.append((body.reduce(CGRect.null) { $0.union(lines[$1].bounds) }, body, [], .code))
        }
        guard !tables.isEmpty else { return }
        // Rules above, below and between the rows reach past the text.
        let ink = InkMap(page: page, bounds: bounds)
        for table in tables {
            let rect = ink?.widened(table.rect) ?? table.rect
            let number = blocks.count
            // Pieces already taken for formulas or pictures inside the table are part of it.
            for index in blocks.indices where !blocks[index].rect.isNull {
                let overlap = blocks[index].rect.intersection(rect.insetBy(dx: -4, dy: -4))
                guard !overlap.isNull, overlap.width * overlap.height >= blocks[index].rect.width * blocks[index].rect.height * 0.5 else { continue }
                for line in lines.indices where lines[line].block == index { lines[line].block = number }
                blocks[index].rect = .null
            }
            for index in table.body { lines[index].block = number }
            for index in table.caption { lines[index].block = nil }
            blocks.append(Block(kind: table.kind, rect: rect, firstLine: table.body.min()))
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// Text with no word of three or more letters, such as `2`, `(3)` or `i=1`.
    /// Labels under a brace in a display, as "transfer" and "weight cost", are a word or two
    /// with none of the small words that join a sentence.
    private static let joiningWords: Set<String> = ["and", "or", "where", "for", "with", "then", "if", "the", "is", "of", "to", "in", "as", "by",
                                                    "at", "on", "so", "be", "we", "let", "since", "hence", "thus", "when", "all", "any", "each", "are", "has", "have"]
    private static func braceLabel(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // A numbered term, as "III: Invariance Penalty" under a brace, is a label too.
        if (2...4).contains(tokens.count), text.range(of: #"^[IVX]{1,4}:\s+\p{Lu}"#, options: .regularExpression) != nil { return true }
        return (1...2).contains(tokens.count) && tokens.allSatisfy { $0.count >= 3 && $0.allSatisfy { $0.isLowercase } && !joiningWords.contains(String($0)) }
    }

    private static func isFragment(_ text: String) -> Bool {
        text.count <= 24 && text.range(of: #"\p{L}{3,}"#, options: .regularExpression) == nil
    }

    /// Short text that labels a drawing rather than reading as a sentence, such as `𝐶`,
    /// `1999 2000 2001` or `140 drownings`.
    private static func isLabel(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // Captions and sentence fragments have several real words; labels have one or two.
        // A line ending in a colon introduces what follows it.
        return !tokens.isEmpty && tokens.count <= 16 && tokens.filter(isWord).count < 3 && !text.hasSuffix(":")
    }

    /// An equation or listing lies in one column. A block whose lines sit on both sides of the
    /// main text column's edge keeps the side holding most of it; the rest goes back to the text.
    private static func separateColumns(_ blocks: inout [Block], lines: inout [Line]) {
        let proseEnds = lines.filter { $0.kind == nil && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 5 }
            .map(\.bounds.maxX).sorted()
        guard !proseEnds.isEmpty else { return }
        let edge = proseEnds[proseEnds.count / 2] + 6
        // Only pages with a real margin column, holding sentences of its own; elsewhere a wide
        // equation simply reaches past the text.
        let marginProse = lines.contains { $0.bounds.minX >= edge && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3 }
        guard marginProse else { return }
        for index in blocks.indices where blocks[index].kind != .image && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }
            let left = members.filter { lines[$0].bounds.minX < edge }, right = members.filter { lines[$0].bounds.minX >= edge }
            guard !left.isEmpty, !right.isEmpty else { continue }
            let leftArea = left.reduce(0) { $0 + lines[$1].bounds.width * lines[$1].bounds.height }
            let rightArea = right.reduce(0) { $0 + lines[$1].bounds.width * lines[$1].bounds.height }
            let (keep, drop) = leftArea >= rightArea ? (left, right) : (right, left)
            for member in drop { lines[member].block = nil }
            blocks[index].rect = keep.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
            blocks[index].firstLine = keep.min()
        }
    }

    /// A formula block whose pieces all sit at the ends of sentences, such as the raised hats and
    /// subscripts of inline math that PDFKit splits off, is part of the text, not a display.
    private static func dissolveInlineBlocks(_ blocks: inout [Block], lines: inout [Line]) {
        let sentences = lines.filter { $0.block == nil && $0.kind == nil && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3 }.map(\.bounds)
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }
            guard !members.isEmpty else { continue }
            // Cross-references such as "(Proposition 8.2):" only appear in sentences.
            let referencing = members.contains { lines[$0].text.range(of: #"\((Equation|Figure|Table|Section|Chapter|Theorem|Lemma|Proposition|Corollary|Definition|Assumption|Example|Appendix)\s*\d"#, options: .regularExpression) != nil }
            let inline = referencing || members.allSatisfy { member in
                let bounds = lines[member].bounds
                return sentences.contains { sentence in
                    min(sentence.maxY, bounds.maxY) - max(sentence.minY, bounds.minY) > min(sentence.height, bounds.height) * 0.3
                        && max(sentence.minX, bounds.minX) - min(sentence.maxX, bounds.maxX) < 16
                }
            }
            guard inline else { continue }
            for member in members { lines[member].block = nil; lines[member].kind = nil }
            blocks[index].rect = .null
            blocks[index].firstLine = nil
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// A sentence between two display equations can end up inside their block, especially in
    /// PDFs whose lines PDFKit breaks into pieces around accents. Each block's lines are grouped
    /// into visual rows; a row that reads as a sentence goes back to the text, and the block is
    /// cut there, keeping the full width of the drawn parts above and below it.
    private static func splitOutProse(from blocks: inout [Block], lines: inout [Line]) {
        let lineHeight = typicalLineHeight(lines.map(\.bounds))
        // Program listings rarely hold mathematical symbols; a "code" block that does is mathematics.
        for index in blocks.indices where blocks[index].kind == .code {
            let members = lines.filter { $0.block == index }
            if members.contains(where: { $0.text.unicodeScalars.contains(where: isTypesetMath) }) { blocks[index].kind = .formula }
        }
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            // Lines lying inside the block count too: drawn parts such as fraction bars can widen
            // a block over text that was never assigned to it.
            let area = blocks[index].rect
            let members = lines.indices.filter { lines[$0].block == index
                || (lines[$0].block == nil && area.contains(CGPoint(x: lines[$0].bounds.midX, y: lines[$0].bounds.midY)))
                || (lines[$0].block == nil && lines[$0].bounds.intersects(area.insetBy(dx: 0, dy: 1))
                    && lines[$0].text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 3) }
                .sorted { lines[$0].bounds.midY > lines[$1].bounds.midY }
            var rows: [[Int]] = []
            for member in members {
                let bounds = lines[member].bounds
                if let last = rows.last, let anchor = last.first,
                   min(lines[anchor].bounds.maxY, bounds.maxY) - max(lines[anchor].bounds.minY, bounds.minY) > min(lines[anchor].bounds.height, bounds.height) * 0.3 {
                    rows[rows.count - 1].append(member)
                } else {
                    rows.append([member])
                }
            }
            func isProse(_ row: [Int]) -> Bool {
                let text = row.sorted { lines[$0].bounds.minX < lines[$1].bounds.minX }.map { lines[$0].text }.joined(separator: " ")
                if text.range(of: #"\(\d+(\.\d+)*[a-z]?( revisited)?\)\s*$"#, options: .regularExpression) != nil { return false }
                // Numbered algorithm steps and their comments belong to the algorithm box.
                if text.range(of: #"^\s*\d{1,3}:\s|▷|//|^\s*(Require|Ensure|Input|Output|return)\b"#, options: .regularExpression) != nil { return false }
                // Subscripts and operator names such as "inv", "gen" or "log" are not words, and a
                // sentence is mostly words rather than symbols.
                let tokens = text.split(whereSeparator: \.isWhitespace)
                let words = tokens.filter { isWord($0) && $0.count >= 3 && !mathWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }.count
                let symbols = text.unicodeScalars.filter(isTypesetMath).count
                let width = row.reduce(CGRect.null) { $0.union(lines[$1].bounds) }.width
                // Three plain words in a row, as in "A change of measure shows", only happen in sentences.
                var run = 0, longest = 0, longWords = 0, best = 0
                for token in tokens {
                    let bare = token.trimmingCharacters(in: .punctuationCharacters)
                    if bare.range(of: #"^\p{L}\p{Ll}*$"#, options: .regularExpression) != nil, !mathWords.contains(bare.lowercased()),
                       bare.count >= 2 || ["a", "A"].contains(bare) {
                        run += 1
                        if bare.count >= 3 { longWords += 1 }
                        if run > longest { longest = run; best = longWords }
                    } else {
                        run = 0
                        longWords = 0
                    }
                }
                let phrase = longest >= 3 && best >= 2
                let wide = width >= min(blocks[index].rect.width, 200) * 0.4
                // Three real words, as "we have … where … because … minimizes … over", are a sentence
                // however much mathematics it holds; a display has a word or two at most.
                let real = tokens.filter { token in
                    let bare = token.replacingOccurrences(of: #"[’']s$"#, with: "", options: .regularExpression).trimmingCharacters(in: .punctuationCharacters)
                    return bare.count >= 4 && bare.allSatisfy(\.isLetter) && !mathWords.contains(bare.lowercased()) && isDictionaryWord(bare.lowercased())
                }.count
                return wide && ((words >= 4 && words * 2 >= tokens.count && symbols <= words) || phrase || real >= 3)
            }
            let prose = rows.indices.filter { isProse(rows[$0]) }
            guard !prose.isEmpty else { continue }
            let original = blocks[index]
            var segments: [[Int]] = [[]]
            var cuts: [(top: CGFloat, bottom: CGFloat)] = []
            for (position, row) in rows.enumerated() {
                if prose.contains(position) {
                    // Pieces of the equation that share the sentence's row, such as a numerator,
                    // stay in the picture; only lines with words are cut out.
                    var wordy = row.filter { lines[$0].text.range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil }
                    // Pieces running on from the sentence along its row, as "2 G+ 1" + "2 a2, so 1"
                    // after "gives aG1/2 ≤ 1", are its inline mathematics.
                    var grown = true
                    while grown && !wordy.isEmpty {
                        grown = false
                        for piece in row where !wordy.contains(piece) && wordy.contains(where: { member in
                            let a = lines[member].bounds, b = lines[piece].bounds
                            // On the sentence's own line, not stacked above or below it as a numerator is.
                            return max(a.minX, b.minX) - min(a.maxX, b.maxX) < 8 && abs(a.midY - b.midY) <= max(a.height, b.height) * 0.25 }) {
                            wordy.append(piece)
                            grown = true
                        }
                    }
                    let pieces = row.filter { !wordy.contains($0) && lines[$0].block == index }
                    let row = wordy.isEmpty ? row : wordy
                    // PDFKit can report a line only as tall as its lowercase letters; the cut
                    // covers a full line so no ascenders or descenders are left in the picture.
                    // A sentence holding inline math can report a much taller box; its letters sit
                    // within a line height of its centre.
                    let rect = row.reduce(CGRect.null) { result, member in
                        let bounds = lines[member].bounds
                        let line = bounds.height > lineHeight * 1.3
                            ? CGRect(x: bounds.minX, y: bounds.midY - lineHeight / 2, width: bounds.width, height: lineHeight)
                            : fullHeight(bounds, lineHeight: lineHeight)
                        return result.union(line)
                    }
                    cuts.append((rect.maxY, rect.minY))
                    for member in row { lines[member].block = nil; lines[member].kind = nil }
                    // Leftover pieces join the part of the equation they overlap most.
                    let above = pieces.filter { lines[$0].bounds.midY > rect.midY }
                    segments[segments.count - 1].append(contentsOf: above)
                    segments.append(pieces.filter { !above.contains($0) })
                } else {
                    segments[segments.count - 1].append(contentsOf: row.filter { lines[$0].block == index })
                    if row.allSatisfy({ lines[$0].block != index }) { segments[segments.count - 1].append(contentsOf: []) }
                }
            }
            // Segment k lies below cut k-1 and above cut k (PDF space runs bottom to top).
            var first = true
            for (position, segment) in segments.enumerated() {
                guard !segment.isEmpty else { continue }
                let top = position == 0 ? original.rect.maxY : cuts[position - 1].bottom - 0.5
                let bottom = position == cuts.count ? original.rect.minY : cuts[position].top + 0.5
                guard top > bottom else { continue }
                let span = segment.reduce(CGRect.null) { $0.union(lines[$1].bounds) }
                let rect = CGRect(x: original.rect.minX, y: max(bottom, original.rect.minY), width: original.rect.width,
                                  height: min(top, original.rect.maxY) - max(bottom, original.rect.minY)).intersection(original.rect.union(span))
                let block = Block(kind: original.kind, rect: rect, firstLine: segment.min())
                if first {
                    blocks[index] = block
                    first = false
                } else {
                    blocks.append(block)
                    for member in segment { lines[member].block = blocks.count - 1 }
                }
            }
            if first {
                blocks[index].rect = .null
                blocks[index].firstLine = nil
            }
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// Two blocks covering much of the same area, such as halves of one algorithm box, become one.
    private static func mergeOverlapping(_ blocks: inout [Block], lines: inout [Line]) {
        var merged = true
        while merged {
            merged = false
            outer: for a in blocks.indices where !blocks[a].rect.isNull {
                for b in blocks.indices where b > a && !blocks[b].rect.isNull {
                    let first = blocks[a].rect, second = blocks[b].rect
                    let overlap = first.intersection(second)
                    let smaller = min(first.width * first.height, second.width * second.height)
                    let narrower = min(first.width, second.width)
                    // Blocks sharing a band of the page across most of their width are one picture,
                    // as are panels of one chart standing a few points apart.
                    let sharesBand = !overlap.isNull && (overlap.width * overlap.height > smaller * 0.3 || (overlap.height >= 3 && overlap.width >= narrower * 0.5))
                    let gapX = max(first.minX, second.minX) - min(first.maxX, second.maxX)
                    let gapY = max(first.minY, second.minY) - min(first.maxY, second.maxY)
                    let panels = blocks[a].kind == .image && blocks[b].kind == .image
                        && ((gapX < 14 && gapY < -min(first.height, second.height) * 0.5) || (gapY < 14 && gapX < -narrower * 0.5))
                    // Stacked pieces of one box, such as the steps of an algorithm, with no text between.
                    var stacked = false
                    if gapY >= 0, gapY < 6, gapX < -narrower * 0.5 {
                        let band = CGRect(x: max(first.minX, second.minX), y: min(first.maxY, second.maxY), width: min(first.maxX, second.maxX) - max(first.minX, second.minX), height: gapY)
                        stacked = !lines.contains { $0.block == nil && !$0.text.isEmpty && $0.bounds.intersects(band.insetBy(dx: 0, dy: -0.5))
                            && $0.bounds.midY > band.minY - 1 && $0.bounds.midY < band.maxY + 1 }
                    }
                    guard sharesBand || panels || stacked else { continue }
                    blocks[a].rect = blocks[a].rect.union(blocks[b].rect)
                    // A listing inside its frame stays code; otherwise the larger part decides.
                    let kinds = Set([blocks[a].kind, blocks[b].kind])
                    if kinds == [.code, .image] {
                        blocks[a].kind = .code
                    } else if second.width * second.height > first.width * first.height {
                        blocks[a].kind = blocks[b].kind
                    }
                    blocks[a].firstLine = [blocks[a].firstLine, blocks[b].firstLine].compactMap { $0 }.min()
                    for line in lines.indices where lines[line].block == b { lines[line].block = a }
                    blocks[b].rect = .null
                    blocks[b].firstLine = nil
                    merged = true
                    break outer
                }
            }
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// Stray pieces of an equation, such as the "∑ w" under a sum or a lone "M :", join the
    /// nearest formula instead of becoming figures of their own.
    private static func absorbFormulaFragments(into blocks: inout [Block], lines: inout [Line]) {
        // Pieces on an equation's row that touch it are part of it: "num−0.5,step_" between
        // "lrate = d−0.5 model·min(step_" and "num·warmup_steps−1.5) (3)", or "where headi =
        // Attention(QWQ" and "i ,KWK" before "i )". Equations that then touch become one.
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5 }
        func touching(_ a: CGRect, _ b: CGRect) -> Bool { sameRow(a, b) && max(a.minX, b.minX) - min(a.maxX, b.maxX) < 4 }
        // The limits of a sum or product, such as "i=1" under ∏, sit just above or below it.
        func limit(_ line: Line, _ block: CGRect) -> Bool {
            // A label under a brace can stand out past the formula's ends.
            let slack: CGFloat = braceLabel(line.text) ? 30 : 2
            return (line.text.count <= 8 && !line.text.contains(where: \.isWhitespace) || braceLabel(line.text)) && line.text.contains(where: { $0.isNumber || $0.isLetter })
                && line.bounds.minX >= block.minX - slack && line.bounds.maxX <= block.maxX + slack
                && max(line.bounds.minY, block.minY) - min(line.bounds.maxY, block.maxY) < 3
        }
        // A row that holds a sentence, as in "(A8) Weight size. δ2 n,inv(ν) ≲ …", is inline mathematics.
        // Function names such as "Attention(" and names such as "warmup_steps" belong to the mathematics.
        func dictionaryWords(_ text: String) -> Int {
            text.matches(of: /[\p{L}\d_]+[(\[]?/).filter { match in
                let name = String(match.output)
                return name.count >= 3 && name.allSatisfy(\.isLetter) && isDictionaryWord(name)
            }.count
        }
        let sentenceRows = lines.filter { dictionaryWords($0.text) >= 2 && !braceLabel($0.text) }.map(\.bounds)
        var joined = true
        while joined {
            joined = false
            // A limit can look like code or a formula of its own.
            for index in lines.indices where lines[index].block == nil && (lines[index].kind == nil || lines[index].text.count <= 8)
                && !sentenceRows.contains(where: { sameRow($0, lines[index].bounds) }) {
                let words = lines[index].text.split(whereSeparator: \.isWhitespace).filter(isWord).count
                let label = braceLabel(lines[index].text)
                guard lines[index].kind == nil || words == 0, words == 0 || label || words <= 2 && lines[index].text.unicodeScalars.contains(where: isMathSymbol),
                      let target = blocks.indices.first(where: { blocks[$0].kind == .formula && !blocks[$0].rect.isNull
                          && (!label && touching(lines[index].bounds, blocks[$0].rect) || (words == 0 || label) && limit(lines[index], blocks[$0].rect)) })
                else { continue }
                lines[index].block = target
                blocks[target].rect = blocks[target].rect.union(lines[index].bounds)
                joined = true
            }
        }
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            for other in blocks.indices where other > index && blocks[other].kind == .formula && !blocks[other].rect.isNull
                && touching(blocks[index].rect, blocks[other].rect) {
                blocks[index].rect = blocks[index].rect.union(blocks[other].rect)
                blocks[index].firstLine = [blocks[index].firstLine, blocks[other].firstLine].compactMap { $0 }.min()
                for line in lines.indices where lines[line].block == other { lines[line].block = index }
                blocks[other].rect = .null
            }
        }
        // A fraction set beside a formula, as "ab" over "gcd(a,b)" after "lcm(a,b) =", is two short
        // pieces stacked one over the other; both join it.
        func short(_ line: Line) -> Bool {
            line.block == nil && !line.text.isEmpty && line.text.count <= 12 && !line.text.contains(" ")
                && !isDictionaryWord(String(line.text.filter(\.isLetter)).lowercased())
        }
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            let rect = blocks[index].rect
            for top in lines.indices where short(lines[top]) {
                let upper = lines[top].bounds
                guard let bottom = lines.indices.first(where: { other in
                    let lower = lines[other].bounds
                    return other != top && short(lines[other]) && lower.maxY <= upper.midY && upper.minY - lower.maxY < 8
                        && min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX) >= min(upper.width, lower.width) * 0.5
                }) else { continue }
                let pair = upper.union(lines[bottom].bounds)
                // Right after the formula, across its middle.
                guard pair.minX >= rect.maxX - 2, pair.minX - rect.maxX < 10, pair.minY < rect.midY, pair.maxY > rect.midY else { continue }
                lines[top].block = index
                lines[bottom].block = index
                blocks[index].rect = rect.union(pair)
                break
            }
        }
        // Only small pieces count: a matrix of short rows inside drawn brackets is a whole formula.
        func isPiece(_ index: Int) -> Bool {
            let rect = blocks[index].rect
            let members = lines.indices.filter { lines[$0].block == index }
            return (rect.width < 40 || rect.height < 16) && !members.isEmpty && members.allSatisfy { lines[$0].text.count <= 6 }
        }
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }
            guard isPiece(index) else { continue }
            let rect = blocks[index].rect
            func distance(_ other: CGRect) -> CGFloat {
                let dx = max(0, max(rect.minX, other.minX) - min(rect.maxX, other.maxX))
                let dy = max(0, max(rect.minY, other.minY) - min(rect.maxY, other.maxY))
                return max(dx, dy)
            }
            guard let target = blocks.indices.filter({ $0 != index && blocks[$0].kind == .formula && !blocks[$0].rect.isNull && distance(blocks[$0].rect) < 30 })
                .min(by: { distance(blocks[$0].rect) < distance(blocks[$1].rect) }) else { continue }
            blocks[target].rect = blocks[target].rect.union(rect)
            blocks[target].firstLine = [blocks[target].firstLine, blocks[index].firstLine].compactMap { $0 }.min()
            for member in members { lines[member].block = target }
            blocks[index].rect = .null
            blocks[index].firstLine = nil
        }
        // A fragment with no formula to join, such as a lone "𝜇0.", stays in the text.
        for index in blocks.indices where blocks[index].kind == .formula && !blocks[index].rect.isNull {
            let members = lines.indices.filter { lines[$0].block == index }
            if isPiece(index) {
                for member in members { lines[member].block = nil }
                blocks[index].rect = .null
                blocks[index].firstLine = nil
            }
        }
        blocks = compacted(blocks, lines: &lines)
    }

    /// Axis labels, legends and table headers sit just outside the drawn part of a figure,
    /// equation numbers beside or below a formula, and split-off pieces beside a line of code.
    private static func attachLabels(to blocks: inout [Block], lines: inout [Line]) {
        let prose = lines.filter { $0.kind == nil && $0.text.split(whereSeparator: \.isWhitespace).filter(isWord).count >= 4 }.map(\.bounds)
        // Text on a sentence's row, or flush left just under one, belongs to the paragraph:
        // a hat accent PDFKit split off, or the short last line of a paragraph.
        func inParagraph(_ bounds: CGRect) -> Bool {
            prose.contains { line in
                let sameRow = min(line.maxY, bounds.maxY) - max(line.minY, bounds.minY) > min(line.height, bounds.height) * 0.3
                    && max(line.minX, bounds.minX) - min(line.maxX, bounds.maxX) < 16
                let below = abs(line.minX - bounds.minX) < 3 && line.minY - bounds.maxY >= -2 && line.minY - bounds.maxY < 10
                return sameRow || below
            }
        }
        var changed = true
        while changed {
            changed = false
            for index in blocks.indices {
                let kind = blocks[index].kind
                let near: CGRect
                switch kind {
                case .image, .table: near = blocks[index].rect.insetBy(dx: -24, dy: -20)
                // A short centred formula can sit far from its number at the margin, on the same row.
                case .formula: near = blocks[index].rect.insetBy(dx: -200, dy: -14)
                case .code: near = blocks[index].rect.insetBy(dx: -12, dy: -1)
                }
                // Formulas only take their equation number, such as "(2.10)", and code only the
                // pieces of a statement the PDF split off on the same row, such as ", ate_est)".
                func belongs(_ text: String) -> Bool {
                    switch kind {
                    case .image, .table: isLabel(text)
                    case .formula: text.range(of: #"^\(\d+(\.\d+)*[a-z]?( revisited)?\)$"#, options: .regularExpression) != nil
                    case .code: text.split(whereSeparator: \.isWhitespace).filter(isWord).count < 2
                    }
                }
                // A label is no wider than what it labels; a full-width line belongs to the text column.
                func reachable(_ bounds: CGRect) -> Bool {
                    guard kind == .formula, !bounds.intersects(blocks[index].rect.insetBy(dx: -60, dy: -14)) else { return true }
                    let rect = blocks[index].rect
                    return min(rect.maxY, bounds.maxY) - max(rect.minY, bounds.minY) > bounds.height * 0.5
                }
                for line in lines.indices where lines[line].block == nil && belongs(lines[line].text) && lines[line].bounds.intersects(near) && reachable(lines[line].bounds)
                    && lines[line].bounds.width <= blocks[index].rect.width + 48 && (kind == .code || !inParagraph(lines[line].bounds)) {
                    lines[line].block = index
                    blocks[index].rect = blocks[index].rect.union(lines[line].bounds)
                    changed = true
                }
            }
        }
    }

    private static func addGraphic(_ region: CGRect, to blocks: inout [Block], lines: inout [Line], pageArea: CGFloat) {
        // Sentences inside a drawn region (boxed text, or ink beside lines) are still read as words.
        func inside(_ line: Line) -> Bool {
            line.block == nil && region.insetBy(dx: -3, dy: -3).contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY))
        }
        func words(_ line: Line) -> Int { line.text.split(whereSeparator: \.isWhitespace).filter(isWord).count }
        // A sentence, or a list of several entries such as a table of contents, is text.
        let containsProse = lines.contains { inside($0) && !isFragment($0.text) && words($0) >= 5 }
            || lines.filter { inside($0) && words($0) >= 3 }.count >= 3
        // Ink inside a row of prose, such as table-of-contents leader dots, is part of the text.
        let insideProseRow = lines.contains { line in
            guard line.kind == nil, words(line) >= 3 else { return false }
            let overlap = line.bounds.intersection(region)
            return !overlap.isNull && overlap.width >= region.width * 0.5 && overlap.height >= min(line.bounds.height, region.height) * 0.5
        }
        if containsProse || insideProseRow { return }
        if let overlapping = blocks.indices.first(where: { blocks[$0].rect.intersects(region) }) {
            let rect = blocks[overlapping].rect
            // Labels inside a chart look like formulas; the drawing decides what the region is.
            if region.width * region.height > rect.width * rect.height { blocks[overlapping].kind = .image }
            blocks[overlapping].rect = rect.union(region)
            // Node and axis labels inside the drawing belong to it, not to the prose.
            for index in lines.indices where lines[index].block == nil && isLabel(lines[index].text)
                && region.insetBy(dx: -3, dy: -3).contains(CGPoint(x: lines[index].bounds.midX, y: lines[index].bounds.midY)) {
                lines[index].block = overlapping
                blocks[overlapping].rect = blocks[overlapping].rect.union(lines[index].bounds)
            }
            return
        }
        // The end of a sentence that leads into the picture, as "node 7 is 4+5+5=14:", is read.
        let inside = lines.indices.filter { lines[$0].block == nil && region.insetBy(dx: -3, dy: -3).contains(CGPoint(x: lines[$0].bounds.midX, y: lines[$0].bounds.midY))
            && !(lines[$0].text.hasSuffix(":") && words(lines[$0]) >= 2) }
        let words = inside.reduce(0) { $0 + TextProcessor.tokenize(lines[$1].text).count }
        // A page-sized region full of words is a background or a scan, not a figure.
        if region.width * region.height > pageArea * 0.6, words > 40 { return }
        blocks.append(Block(kind: .image, rect: region, firstLine: nil))
        for index in inside { lines[index].block = blocks.count - 1 }
    }

    /// Finds drawn content that is not text by rendering the page with text lines blanked out.
    /// The tallest ordinary line box on the page, standing in for the type size. Pages where
    /// every box is squashed, such as an index, still get a realistic line of 9 points.
    private static func typicalLineHeight(_ rects: [CGRect]) -> CGFloat {
        max(9, rects.map(\.height).sorted().last { $0 <= 16 } ?? 10)
    }

    /// Some PDFs report boxes only as tall as lowercase letters; this grows a box to a full
    /// line, centred on the original, so ascenders and descenders are covered.
    private static func fullHeight(_ rect: CGRect, lineHeight: CGFloat) -> CGRect {
        rect.insetBy(dx: 0, dy: -max(0, (lineHeight - rect.height) / 2))
    }

    /// Drawings on the page: clusters of ink left after blanking out the text. Clusters are
    /// found in two dimensions, so a diagram in the margin beside the text stands on its own.
    private static func graphicRegions(on page: PDFPage, bounds: CGRect, textRects: [CGRect], labels: [CGRect]) -> [CGRect] {
        let width = Int(bounds.width.rounded(.up)), height = Int(bounds.height.rounded(.up))
        guard width > 0, height > 0, width * height <= 6_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: context)
        for rect in textRects {
            context.fill(rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY).insetBy(dx: -1.5, dy: -1.5))
        }
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }

        // Inked cells on a coarse grid, joined when within a couple of cells of each other.
        let cell = 3
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var inked = [Bool](repeating: false, count: columns * rows)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width where data[base + x] < 200 {
                inked[(y / cell) * columns + x / cell] = true
            }
        }
        // Ink joins further up and down than sideways: blanking a node letter leaves its circle
        // as two arcs a line apart, while the text column and the margin sit side by side.
        let reach = 3, verticalReach = 6
        var label = [Int](repeating: -1, count: columns * rows)
        var regions: [CGRect] = []
        var nodes: [CGRect] = []
        var dots: [CGRect] = []
        for start in inked.indices where inked[start] && label[start] < 0 {
            var queue = [start]
            label[start] = start
            var minX = columns, maxX = 0, minY = rows, maxY = 0, count = 0
            while let current = queue.popLast() {
                let cx = current % columns, cy = current / columns
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy); count += 1
                for ny in max(0, cy - verticalReach)...min(rows - 1, cy + verticalReach) {
                    for nx in max(0, cx - reach)...min(columns - 1, cx + reach) {
                        let next = ny * columns + nx
                        if inked[next], label[next] < 0 {
                            label[next] = start
                            queue.append(next)
                        }
                    }
                }
            }
            let rect = CGRect(x: minX * cell, y: minY * cell, width: (maxX - minX + 1) * cell, height: (maxY - minY + 1) * cell)
            // Memory rows run top to bottom; PDF space runs bottom to top.
            let placed = CGRect(x: bounds.minX + rect.minX, y: bounds.minY + CGFloat(height) - rect.maxY,
                                width: min(rect.width, CGFloat(width) - rect.minX), height: rect.height)
            // Wide or tall: a column of nodes joined by an edge is as much a drawing as a row.
            // A column as narrow as one node, as "2" over "5" joined by an edge, counts too when an
            // unbroken stroke runs down it; a column of leader dots has none.
            func stroke() -> Bool {
                for x in Int(rect.minX)..<min(width, Int(rect.maxX)) {
                    var run = 0
                    for y in Int(rect.minY)..<min(height, Int(rect.maxY)) {
                        run = data[y * width + x] < 200 ? run + 1 : 0
                        if run >= 15 { return true }
                    }
                }
                return false
            }
            if rect.height >= 16 && rect.width >= 40 || rect.height >= 40 && (rect.width >= 16 || rect.width >= 10 && stroke()), count >= 12 {
                // Brackets, commas and descenders reaching past the boxes of lines of text are no
                // drawing: some of a drawing's ink stands clear of the text.
                let clear = textRects.filter { $0.intersects(placed) }.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY).insetBy(dx: -2, dy: -3.5) }
                var stray = 0
                for y in Int(rect.minY)..<min(height, Int(rect.maxY)) where stray < 20 {
                    let point = CGFloat(height - y) - 0.5
                    for x in Int(rect.minX)..<min(width, Int(rect.maxX)) where data[y * width + x] < 200
                        && !clear.contains(where: { $0.contains(CGPoint(x: CGFloat(x) + 0.5, y: point)) }) {
                        stray += 1
                    }
                }
                if stray >= 20 { regions.append(placed) }
            } else if (10...40).contains(rect.width), (10...40).contains(rect.height), rect.width / rect.height > 0.7, rect.width / rect.height < 1.4,
                      labels.reduce(0, { covered, label in
                          let overlap = label.intersection(placed)
                          return covered + (overlap.isNull ? 0 : overlap.width * overlap.height)
                      }) < placed.width * placed.height * 0.4 {
                // A round or square shape the size of a graph node, such as a circle with no edges,
                // around a small label; short text left on the page, such as "[1]", is not one.
                nodes.append(placed)
            } else if (3...10).contains(rect.width), (3...10).contains(rect.height), rect.width / rect.height > 0.7, rect.width / rect.height < 1.4,
                      !labels.contains(where: { $0.intersects(placed) }) {
                // A point of a scatter of points, as in a convex hull example.
                dots.append(placed)
            }
        }
        // Lone nodes belong to the drawing beside them; several close together are a drawing.
        func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(max(a.minX, b.minX) - min(a.maxX, b.maxX), max(a.minY, b.minY) - min(a.maxY, b.maxY))
        }
        var loose: [CGRect] = []
        for node in nodes {
            if let near = regions.indices.first(where: { gap(regions[$0], node) < 30 }) { regions[near] = regions[near].union(node) } else { loose.append(node) }
        }
        var clusters: [[CGRect]] = []
        for node in loose {
            let joined = clusters.indices.filter { clusters[$0].contains { gap($0, node) < 40 } }
            var merged = joined.flatMap { clusters[$0] } + [node]
            for index in joined.reversed() { clusters.remove(at: index) }
            merged.sort { $0.minX < $1.minX }
            clusters.append(merged)
        }
        for cluster in clusters where cluster.count >= 3 {
            regions.append(cluster.dropFirst().reduce(cluster[0]) { $0.union($1) })
        }
        // Five or more points close together are a scatter plot.
        var scatters: [[CGRect]] = []
        for dot in dots where !regions.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(dot) }) {
            let joined = scatters.indices.filter { scatters[$0].contains { gap($0, dot) < 100 } }
            let merged = joined.flatMap { scatters[$0] } + [dot]
            for index in joined.reversed() { scatters.remove(at: index) }
            scatters.append(merged)
        }
        for scatter in scatters where scatter.count >= 5 {
            regions.append(scatter.dropFirst().reduce(scatter[0]) { $0.union($1) })
        }
        return regions
    }

    /// Index of the first text line below the region that shares its column.
    private static func placement(of rect: CGRect, among lines: [Line]) -> Int {
        lines.indices.first { index in
            let bounds = lines[index].bounds
            guard lines[index].block == nil, bounds.midY < rect.minY else { return false }
            if bounds.maxX > rect.minX && bounds.minX < rect.maxX { return true }
            // A heading at the margin below a centred picture, as "Existence", comes after it when
            // the text read before it is above the picture.
            guard !lines[index].small, !lines[index].text.isEmpty, bounds.maxX <= rect.minX else { return false }
            let previous = lines[..<index].last { $0.block == nil && !$0.text.isEmpty }
            return previous.map { $0.bounds.midY > rect.maxY } ?? false
        } ?? lines.count
    }

    /// Cuts off a thin strip of ink along the top or bottom edge that is separated from the rest
    /// by blank rows: the tops or tails of a neighbouring line of text caught by the crop.
    private static func trimmingEdgeSlivers(_ image: CGImage, in context: CGContext, scale: CGFloat) -> CGImage? {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        func inked(_ row: Int) -> Bool {
            let base = row * stride
            for x in 0..<width where Int(data[base + x * 4]) + Int(data[base + x * 4 + 1]) + Int(data[base + x * 4 + 2]) < 600 {
                return true
            }
            return false
        }
        let rows = (0..<height).map(inked)
        let sliver = Int(4.5 * scale), gap = max(2, Int(1 * scale))
        // Memory rows run top to bottom.
        func edgeCut(_ order: [Int]) -> Int {
            var index = 0
            while index < order.count, rows[order[index]] { index += 1 }
            guard index > 0, index <= sliver else { return 0 }
            var blank = index
            while blank < order.count, !rows[order[blank]] { blank += 1 }
            return blank - index >= gap && blank < order.count ? blank : 0
        }
        let top = edgeCut(Array(0..<height)), bottom = edgeCut(Array((0..<height).reversed()))
        // At the sides, a narrow strip of ink touching the very edge is part of a neighbouring
        // character; the padding keeps the crop's own ink off the edge.
        func inkedColumn(_ column: Int) -> Bool {
            for row in top..<(height - bottom) {
                let base = row * stride + column * 4
                if Int(data[base]) + Int(data[base + 1]) + Int(data[base + 2]) < 600 { return true }
            }
            return false
        }
        func sideCut(_ order: [Int]) -> Int {
            var index = 0
            while index < order.count, inkedColumn(order[index]) { index += 1 }
            guard index > 0, index <= Int(1.5 * scale) else { return 0 }
            var blank = index
            while blank < order.count, !inkedColumn(order[blank]) { blank += 1 }
            return blank - index >= max(1, Int(0.5 * scale)) && blank < order.count ? blank : 0
        }
        let left = sideCut(Array(0..<width)), right = sideCut(Array((0..<width).reversed()))
        guard top > 0 || bottom > 0 || left > 0 || right > 0, height - top - bottom > gap, width - left - right > gap else { return nil }
        return image.cropping(to: CGRect(x: left, y: top, width: width - left - right, height: height - top - bottom))
    }

    /// Whether a rendered picture shows more than a speck of ink.
    /// A picture whose ink is shorter than a small letter shows only accents or rules, as when
    /// PDFKit reports a box above the glyphs it belongs to.
    private static func hasInk(_ data: Data, crop: CGRect? = nil) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = min(image.width, 400), height = max(1, image.height * width / max(image.width, 1))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var ink = 0, top = height, bottom = -1
        for index in 0..<(width * height) where pixels[index] < 160 {
            ink += 1
            top = min(top, index / width)
            bottom = max(bottom, index / width)
        }
        guard ink >= 12 else { return false }
        guard let crop, crop.height > 0 else { return true }
        // Rows of the downscaled picture back to points on the page.
        let points = CGFloat(bottom - top + 1) * crop.height / CGFloat(height)
        return points >= 3.5
    }

    /// Pictures placed in a row on white, centred vertically, for an expression split over two lines.
    private static func joinedSideBySide(_ pictures: [Data]) -> Data? {
        let images = pictures.compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard !images.isEmpty else { return nil }
        let gap = 18
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        let height = images.map(\.height).max() ?? 0
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            context.draw(image, in: CGRect(x: x, y: (height - image.height) / 2, width: image.width, height: image.height))
            x += image.width + gap
        }
        guard let joined = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, joined, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func renderPNG(of page: PDFPage, rect: CGRect, pageBounds: CGRect, erasing: [CGRect] = []) -> Data? {
        let crop = rect.intersection(pageBounds)
        guard !crop.isNull, crop.width >= 4, crop.height >= 4 else { return nil }
        let scale = min(3, 2400 / max(crop.width, crop.height))
        let width = Int((crop.width * scale).rounded(.up)), height = Int((crop.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: pageBounds.minX - crop.minX, y: pageBounds.minY - crop.minY)
        page.draw(with: .cropBox, to: context)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for area in erasing { context.fill(area.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)) }
        guard let full = context.makeImage() else { return nil }
        let trimmed = trimmingEdgeSlivers(full, in: context, scale: scale) ?? full
        // A white margin keeps ink off the picture's edges, so a tight crop does not look cut.
        let margin = Int((scale * 1.5).rounded())
        var image = trimmed
        if let padded = CGContext(data: nil, width: trimmed.width + margin * 2, height: trimmed.height + margin * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            padded.setFillColor(CGColor(gray: 1, alpha: 1))
            padded.fill(CGRect(x: 0, y: 0, width: padded.width, height: padded.height))
            padded.draw(trimmed, in: CGRect(x: margin, y: margin, width: trimmed.width, height: trimmed.height))
            image = padded.makeImage() ?? trimmed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The page, or a part of it, drawn four times finer than `InkMap`, where glyphs that touch at one
/// pixel per point, as the "g" and subscript "2" of "log₂", come apart.
private struct FineInk {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let rect: CGRect
    let scale: CGFloat = 4

    init?(page: PDFPage, pageBounds: CGRect, rect: CGRect) {
        let width = Int((rect.width * 4).rounded(.up)), height = Int((rect.height * 4).rounded(.up))
        guard width > 0, height > 0, width * height <= 12_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 4, y: 4)
        context.translateBy(x: pageBounds.minX - rect.minX, y: pageBounds.minY - rect.minY)
        page.draw(with: .cropBox, to: context)
        self.pixels = Array(UnsafeBufferPointer(start: data, count: width * height))
        self.width = width
        self.height = height
        self.rect = rect
    }

    /// The signs drawn in `area` without characters, told by their shape, as "∅," or "\\"; nil
    /// when any glyph there is something else.
    func signs(in area: CGRect, baseline: CGFloat, size: CGFloat) -> String? {
        // Slivers of the neighbouring letters at the area's edges are no signs.
        let found = glyphs(in: area).filter { glyph in
            let width = glyph.span.upperBound - glyph.span.lowerBound
            let edge = glyph.span.lowerBound <= area.minX + 0.5 || glyph.span.upperBound >= area.maxX - 0.5
            return width >= 0.6 && !(edge && width < 1.5)
        }
        guard !found.isEmpty, found.count <= 8 else { return nil }
        var result = ""
        for glyph in found {
            let width = glyph.span.upperBound - glyph.span.lowerBound, height = glyph.top - glyph.bottom
            // The pixels of the glyph, top row first.
            let left = Int(((glyph.span.lowerBound - rect.minX) * scale).rounded()), right = Int(((glyph.span.upperBound - rect.minX) * scale).rounded()) - 1
            let top = Int(((rect.maxY - glyph.top) * scale).rounded()), bottom = Int(((rect.maxY - glyph.bottom) * scale).rounded()) - 1
            guard left >= 0, right < self.width, top >= 0, bottom < self.height, right - left >= 1, bottom - top >= 1 else { return nil }
            func inked(_ row: Int, _ column: Int) -> Bool { pixels[row * self.width + column] < 160 }
            func runs(row: Int) -> [Range<Int>] {
                var found: [Range<Int>] = [], start: Int?
                for column in left...right + 1 {
                    let on = column <= right && inked(row, column)
                    if on, start == nil { start = column }
                    if !on, let first = start { found.append(first..<column); start = nil }
                }
                return found
            }
            func runs(column: Int) -> Int {
                var count = 0, on = false
                for row in top...bottom { let now = inked(row, column); if now && !on { count += 1 }; on = now }
                return count
            }
            let rows = Array(top...bottom), middle = rows.filter { CGFloat($0 - top) >= CGFloat(bottom - top) * 0.3 && CGFloat($0 - top) <= CGFloat(bottom - top) * 0.7 }
            let columns = Array(left...right).filter { CGFloat($0 - left) >= CGFloat(right - left) * 0.35 && CGFloat($0 - left) <= CGFloat(right - left) * 0.65 }
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            let rowRuns = middle.map { runs(row: $0).count }, columnRuns = columns.map { runs(column: $0) }
            func spans(_ row: Int) -> Bool { runs(row: row).reduce(0) { $0 + $1.count } >= (right - left + 1) * 8 / 10 }
            let ratio = width / max(height, 0.1)
            if height <= size * 0.4, width <= size * 0.3, glyph.bottom < baseline - 0.4 {
                result += ","
            } else if height <= size * 0.22, width <= size * 0.22 {
                result += "."
            } else if height >= size * 0.55, !middle.isEmpty, !columns.isEmpty {
                let edges = Array(rows.prefix(max(1, rows.count / 8))) + Array(rows.suffix(max(1, rows.count / 8)))
                let sideRuns = middle.map(runs(row:))
                // The ring's stroke reaches below the baseline and well above the letters' middle.
                let hangs = glyph.bottom <= baseline - size * 0.04 && glyph.top >= baseline + size * 0.6
                if hangs, (0.55...1.25).contains(ratio), median(rowRuns) >= 3 || median(rowRuns) == 2 && median(columnRuns) >= 3 {
                    result += "∅"
                } else if hangs, ratio <= 0.8, rowRuns.allSatisfy({ $0 == 1 }), let first = runs(row: top).first, let last = runs(row: bottom).first,
                          last.lowerBound - first.lowerBound >= (right - left) / 2 {
                    result += "\\"
                } else if (0.7...1.4).contains(ratio), let box = { () -> String? in
                    // A box's sides: a stroke runs along a side when nearly every row, or column,
                    // has ink within a quarter of the glyph from it; the middle stays blank.
                    let w = right - left + 1, h = bottom - top + 1, qw = max(1, w / 4), qh = max(1, h / 4)
                    func share(_ hits: Int, _ of: Int) -> Double { Double(hits) / Double(of) }
                    let leftSide = share(rows.filter { row in (left..<(left + qw)).contains { inked(row, $0) } }.count, h)
                    let rightSide = share(rows.filter { row in ((right - qw + 1)...right).contains { inked(row, $0) } }.count, h)
                    let cols = Array(left...right)
                    let topSide = share(cols.filter { column in (top..<(top + qh)).contains { inked($0, column) } }.count, w)
                    let bottomSide = share(cols.filter { column in ((bottom - qh + 1)...bottom).contains { inked($0, column) } }.count, w)
                    let middle = ((top + qh + 1)..<max(top + qh + 2, bottom - qh)).contains { row in ((left + qw + 1)..<max(left + qw + 2, right - qw)).contains { inked(row, $0) } }
                    guard !middle, topSide >= 0.8, bottomSide >= 0.8 else { return nil }
                    switch (leftSide >= 0.8, rightSide >= 0.8) {
                    case (true, true): return "□"
                    case (true, false): return "⊏"
                    case (false, true): return "⊐"
                    default: return nil
                    }
                }() {
                    result += box                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return result.contains(where: { "∅\\□⊏⊐".contains($0) }) ? result : nil
    }

    /// The glyphs in `area` as runs of connected ink, left to right, with where their ink ends
    /// below and above. Pieces stacked over one another, as the dot of an "i" or the bars of "=",
    /// are one glyph.
    func glyphs(in area: CGRect, stacking: Bool = true) -> [(span: Range<CGFloat>, bottom: CGFloat, top: CGFloat)] {
        let left = max(0, Int(((area.minX - rect.minX) * scale).rounded())), right = min(width - 1, Int(((area.maxX - rect.minX) * scale).rounded()) - 1)
        let top = max(0, Int(((rect.maxY - area.maxY) * scale).rounded())), bottom = min(height - 1, Int(((rect.maxY - area.minY) * scale).rounded()) - 1)
        guard left <= right, top <= bottom else { return [] }
        var seen = Set<Int>()
        var pieces: [(minX: Int, maxX: Int, minRow: Int, maxRow: Int)] = []
        for row in top...bottom {
            for column in left...right where pixels[row * width + column] < 160 && !seen.contains(row * width + column) {
                var stack = [row * width + column], piece = (minX: column, maxX: column, minRow: row, maxRow: row)
                seen.insert(row * width + column)
                while let next = stack.popLast() {
                    let y = next / width, x = next % width
                    piece = (min(piece.minX, x), max(piece.maxX, x), min(piece.minRow, y), max(piece.maxRow, y))
                    for dy in -1...1 { for dx in -1...1 {
                        let ny = y + dy, nx = x + dx
                        guard ny >= top, ny <= bottom, nx >= left, nx <= right, pixels[ny * width + nx] < 160, !seen.contains(ny * width + nx) else { continue }
                        seen.insert(ny * width + nx)
                        stack.append(ny * width + nx)
                    } }
                }
                // Specks of a pixel or two are antialiasing, not glyphs, and a sliver at the area's
                // side is the edge of a neighbour.
                let sliver = piece.maxX - piece.minX < 2 && (piece.minX == left || piece.maxX == right)
                if (piece.maxX - piece.minX + 1) * (piece.maxRow - piece.minRow + 1) > 2, !sliver { pieces.append(piece) }
            }
        }
        pieces.sort { $0.minX < $1.minX }
        var merged: [(minX: Int, maxX: Int, minRow: Int, maxRow: Int)] = []
        for piece in pieces {
            if stacking, let last = merged.last, min(last.maxX, piece.maxX) - max(last.minX, piece.minX) + 1 >= (min(last.maxX - last.minX, piece.maxX - piece.minX) + 1) / 2 {
                merged[merged.count - 1] = (min(last.minX, piece.minX), max(last.maxX, piece.maxX), min(last.minRow, piece.minRow), max(last.maxRow, piece.maxRow))
            } else {
                merged.append(piece)
            }
        }
        return merged.map { piece in
            ((rect.minX + CGFloat(piece.minX) / scale)..<(rect.minX + CGFloat(piece.maxX + 1) / scale),
             rect.maxY - CGFloat(piece.maxRow + 1) / scale, rect.maxY - CGFloat(piece.minRow) / scale)
        }
    }
}

/// The page drawn finer, once, when a line first needs it.
private final class FinerPage {
    var map: FineInk??
}

/// The page rendered in grey at one pixel per point, for following ink beyond text boxes.
private struct InkMap {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let bounds: CGRect
    private let finerPage = FinerPage()

    func finer(_ page: PDFPage) -> FineInk? {
        if finerPage.map == nil { finerPage.map = .some(FineInk(page: page, pageBounds: bounds, rect: bounds)) }
        return finerPage.map ?? nil
    }

    init?(page: PDFPage, bounds: CGRect) {
        let width = Int(bounds.width.rounded(.up)), height = Int(bounds.height.rounded(.up))
        guard width > 0, height > 0, width * height <= 6_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: context)
        self.pixels = Array(UnsafeBufferPointer(start: data, count: width * height))
        self.width = width
        self.height = height
        self.bounds = bounds
    }

    /// `rect` grown sideways until no glyph is cut at its left and right edges: a glyph is cut
    /// where a row is inked on both sides of the edge. It never grows past `left` or `right`.
    func completingGlyphs(_ rect: CGRect, left: CGFloat?, right: CGFloat?) -> CGRect {
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY) - 1)
        guard top <= bottom else { return rect }
        func ink(_ column: Int) -> [Bool] { (top...bottom).map { column >= 0 && column < width && pixels[$0 * width + column] < 160 } }
        func cut(_ inside: Int, _ outside: Int) -> Bool { zip(ink(inside), ink(outside)).contains { $0 && $1 } }
        var result = rect
        var edge = Int((rect.maxX - bounds.minX).rounded())
        let rightLimit = right.map { Int(($0 - bounds.minX - 0.5).rounded(.down)) } ?? width
        var moved = 0
        while edge < width - 1, edge < rightLimit, moved < 14, cut(edge - 1, edge) { edge += 1; moved += 1 }
        if moved > 0 { result.size.width = bounds.minX + CGFloat(edge) + 0.5 - result.minX }
        edge = Int((rect.minX - bounds.minX).rounded())
        let leftLimit = left.map { Int(($0 - bounds.minX + 0.5).rounded(.up)) } ?? 0
        moved = 0
        while edge > 0, edge > leftLimit, moved < 14, cut(edge, edge - 1) { edge -= 1; moved += 1 }
        // A sign drawn without a character, as the "∑" of "∑e pe", stands in the space before
        // the expression; up to the word before, ink close by belongs to it.
        if left != nil {
            var probe = edge - 1, blank = 0, reach = edge
            while probe > leftLimit, blank <= 2 {
                if ink(probe).contains(true) { reach = probe; blank = 0 } else { blank += 1 }
                probe -= 1
            }
            if reach < edge, edge - reach <= 24 { moved += edge - reach; edge = reach }
        }
        if moved > 0 {
            let maxX = result.maxX
            result.origin.x = bounds.minX + CGFloat(edge) - 0.5
            result.size.width = maxX - result.minX
        }
        return result
    }

    private func inked(column: Int, rows: ClosedRange<Int>) -> Bool {
        guard column >= 0, column < width else { return false }
        return rows.contains { pixels[$0 * width + column] < 200 }
    }

    /// Whether the row just past `rect`'s top or bottom edge is blank across its width.
    func blankRow(above: Bool, of rect: CGRect) -> Bool {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let row = above ? Int(bounds.maxY - rect.maxY) - 1 : Int(bounds.maxY - rect.minY) + 1
        guard left <= right, row >= 0, row < height else { return false }
        return !(left...right).contains { pixels[row * width + $0] < 200 }
    }

    /// The horizontal extents of separate inked runs inside `rect`, left to right, in page space.
    func glyphColumns(in rect: CGRect) -> [Range<CGFloat>] {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return [] }
        var runs: [Range<CGFloat>] = [], start: Int?
        for column in left...right + 1 {
            let inked = column <= right && (top...bottom).contains { pixels[$0 * width + column] < 160 }
            if inked, start == nil { start = column }
            if !inked, let first = start {
                runs.append((bounds.minX + CGFloat(first))..<(bounds.minX + CGFloat(column)))
                start = nil
            }
        }
        return runs
    }

    /// Thin rules near the top or bottom of `rect` with blank rows on both sides, as the separator
    /// of the footnotes that a display's crop reaches.
    func separatedRules(in rect: CGRect) -> [CGRect] {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left < right, top + 2 < bottom else { return [] }
        func inked(_ row: Int, _ column: Int) -> Bool { row >= 0 && row < height && pixels[row * width + column] < 160 }
        var rules: [CGRect] = []
        for row in Array(top...min(bottom, top + 6)) + Array(max(top, bottom - 6)...bottom) {
            var column = left
            while column <= right {
                guard inked(row, column) else { column += 1; continue }
                let start = column
                while column <= right, inked(row, column) { column += 1 }
                guard column - start >= 30 else { continue }
                // Its rows: the ones inked along most of the run, at most two.
                let span = start..<column
                func along(_ other: Int) -> Bool { span.filter { inked(other, $0) }.count * 10 >= span.count * 8 }
                var first = row, last = row
                while first - 1 >= top, along(first - 1) { first -= 1 }
                while last + 1 <= bottom, along(last + 1) { last += 1 }
                func blank(_ other: Int) -> Bool { span.filter { inked(other, $0) }.count * 10 <= span.count }
                guard last - first <= 1, blank(first - 1), blank(last + 1) else { continue }
                let rule = CGRect(x: bounds.minX + CGFloat(start) - 1, y: bounds.maxY - CGFloat(last + 1) - 1, width: CGFloat(column - start) + 2, height: CGFloat(last - first + 1) + 2)
                if !rules.contains(where: { $0.intersects(rule) }) { rules.append(rule) }
            }
        }
        return rules
    }

    /// The box of the ink in `rect` outside all of `excluded`.
    func inkBounds(in rect: CGRect, excluding excluded: [CGRect]) -> CGRect? {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return nil }
        var result = CGRect.null
        for row in top...bottom {
            for column in left...right where pixels[row * width + column] < 160 {
                let point = CGRect(x: bounds.minX + CGFloat(column), y: bounds.maxY - CGFloat(row + 1), width: 1, height: 1)
                if !excluded.contains(where: { $0.contains(CGPoint(x: point.midX, y: point.midY)) }) { result = result.union(point) }
            }
        }
        return result.isNull ? nil : result
    }

    /// `rect` without the rows near its top and bottom that are inked nearly all the way across,
    /// such as the rule of a frame.
    func withoutRules(_ rect: CGRect) -> CGRect {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard right - left >= 20, top <= bottom else { return rect }
        var trimmed = rect
        for row in top...bottom where (left...right).filter({ pixels[row * width + $0] < 160 }).count * 10 >= (right - left + 1) * 9 {
            let y = bounds.maxY - CGFloat(row)
            // A row covers the point below its top edge.
            if y - 1 > rect.midY { trimmed = CGRect(x: trimmed.minX, y: trimmed.minY, width: trimmed.width, height: min(trimmed.maxY, y - 1.5) - trimmed.minY) }
            else if y < rect.midY { trimmed = CGRect(x: trimmed.minX, y: max(trimmed.minY, y + 0.5), width: trimmed.width, height: trimmed.maxY - max(trimmed.minY, y + 0.5)) }
        }
        return trimmed.height > 2 ? trimmed : rect
    }

    /// The highest inked point inside `rect`, in page space.
    func highestInk(in rect: CGRect) -> CGFloat? {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return nil }
        for row in top...bottom where (left...right).contains(where: { pixels[row * width + $0] < 160 }) {
            return bounds.maxY - CGFloat(row)
        }
        return nil
    }

    /// The lowest inked point inside `rect`, in page space.
    func lowestInk(in rect: CGRect) -> CGFloat? {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return nil }
        for row in stride(from: bottom, through: top, by: -1) where (left...right).contains(where: { pixels[row * width + $0] < 160 }) {
            return bounds.maxY - CGFloat(row + 1)
        }
        return nil
    }

    /// How many inked points lie in `rect` outside all of `excluded`.
    func inkCount(in rect: CGRect, excluding excluded: [CGRect]) -> Int {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return 0 }
        let nearby = excluded.filter { $0.intersects(rect) }
        var count = 0
        for row in top...bottom {
            let y = bounds.maxY - CGFloat(row) - 0.5
            for column in left...right where pixels[row * width + column] < 160 {
                let point = CGPoint(x: bounds.minX + CGFloat(column) + 0.5, y: y)
                if !nearby.contains(where: { $0.contains(point) }) { count += 1 }
            }
        }
        return count
    }

    /// The band of ink at the top or bottom of `rect` that spans its width, apart from other ink
    /// below or above it, as a line of text is.
    func edgeTextBand(in rect: CGRect, atLeast minimum: CGFloat) -> CGRect? {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard right - left > 20, top < bottom else { return nil }
        var bands: [ClosedRange<Int>] = [], start: Int?
        for row in top...bottom + 1 {
            let inked = row <= bottom && (left...right).contains { pixels[row * width + $0] < 160 }
            if inked, start == nil { start = row }
            if !inked, let first = start { bands.append(first...(row - 1)); start = nil }
        }
        guard bands.count >= 2 else { return nil }
        // The descenders of the line above make a thin band of their own.
        for band in [bands.first!, bands.last!] where CGFloat(band.count) <= rect.height * 0.45 && CGFloat(band.count) >= minimum {
            let columns = (left...right).filter { column in band.contains { pixels[$0 * width + column] < 160 } }
            guard let first = columns.first, let last = columns.last, first - left <= 6, right - last <= 6 else { continue }
            return CGRect(x: rect.minX, y: bounds.maxY - CGFloat(band.upperBound + 1), width: rect.width, height: CGFloat(band.count))
        }
        return nil
    }

    /// The runs of rows inside `rect` that hold ink, from the bottom up, in page coordinates.
    func rowBands(in rect: CGRect) -> [Range<CGFloat>] {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left < right, top < bottom else { return [] }
        var bands: [Range<CGFloat>] = [], start: Int?
        for row in top...bottom + 1 {
            let inked = row <= bottom && (left...right).contains { pixels[row * width + $0] < 160 }
            if inked, start == nil { start = row }
            if !inked, let first = start { bands.append((bounds.maxY - CGFloat(row))..<(bounds.maxY - CGFloat(first))); start = nil }
        }
        return bands.reversed()
    }

    /// Whether anything is drawn inside `rect`.
    func inked(_ rect: CGRect) -> Bool {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard left <= right, top <= bottom else { return false }
        return (top...bottom).contains { row in (left...right).contains { pixels[row * width + $0] < 200 } }
    }

    /// `rect` grown to one side while ink continues on its rows with gaps no wider than `gap`.
    func extended(_ rect: CGRect, right: Bool, gap: CGFloat) -> CGRect {
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard top <= bottom else { return rect }
        let rows = top...bottom
        let step = right ? 1 : -1
        var column = right ? Int(rect.maxX - bounds.minX) : Int(rect.minX - bounds.minX)
        var last = column, blank = 0
        while column >= 0, column < width, CGFloat(blank) <= gap {
            if inked(column: column, rows: rows) { last = column; blank = 0 } else { blank += 1 }
            column += step
        }
        let edge = bounds.minX + CGFloat(last)
        return right ? CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, edge + 1 - rect.minX), height: rect.height)
            : CGRect(x: min(rect.minX, edge), y: rect.minY, width: rect.maxX - min(rect.minX, edge), height: rect.height)
    }

    /// `rect` grown up and down, by at most `limit`, while its columns still hold ink.
    func grownVertically(_ rect: CGRect, limit: CGFloat) -> CGRect {
        let left = max(0, Int(rect.minX - bounds.minX)), right = min(width - 1, Int(rect.maxX - bounds.minX))
        guard left <= right else { return rect }
        func inked(row: Int) -> Bool {
            guard row >= 0, row < height else { return false }
            return (left...right).contains { pixels[row * width + $0] < 200 }
        }
        // Memory rows run top to bottom; PDF space runs bottom to top.
        var top = Int(bounds.maxY - rect.maxY), bottom = Int(bounds.maxY - rect.minY)
        let steps = Int(limit)
        for _ in 0..<steps where inked(row: top - 1) { top -= 1 }
        for _ in 0..<steps where inked(row: bottom + 1) { bottom += 1 }
        return CGRect(x: rect.minX, y: bounds.maxY - CGFloat(bottom), width: rect.width, height: CGFloat(bottom - top))
    }

    /// `rect` grown sideways while ink continues on its rows, up to a 10-point blank gap.
    func widened(_ rect: CGRect) -> CGRect {
        // Memory rows run top to bottom; PDF space runs bottom to top.
        let top = max(0, Int(bounds.maxY - rect.maxY)), bottom = min(height - 1, Int(bounds.maxY - rect.minY))
        guard top <= bottom else { return rect }
        let rows = top...bottom
        func reach(from start: Int, step: Int) -> Int {
            var column = start, last = start, blank = 0
            while column >= 0, column < width, blank < 10 {
                if inked(column: column, rows: rows) { last = column; blank = 0 } else { blank += 1 }
                column += step
            }
            return last
        }
        let left = reach(from: Int(rect.minX - bounds.minX), step: -1)
        let right = reach(from: Int(rect.maxX - bounds.minX), step: 1)
        return CGRect(x: bounds.minX + CGFloat(left), y: rect.minY, width: CGFloat(right - left + 1), height: rect.height)
    }
}
