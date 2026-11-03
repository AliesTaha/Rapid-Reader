import AppKit

/// Splits words that a PDF printed without a gap between them, such as "anideaofwhat", into
/// dictionary words ("an idea of what"), using the system spelling dictionary.
enum WordSplitter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Bool] = [:]

    /// Pieces of four letters or fewer must be common words, so a run is not chopped into rare
    /// fragments that happen to be in the dictionary ("reweigh ting", "wha tit"). Common words
    /// also win ties: "graphsand" is "graphs and", not "graph sand".
    private static let commonWords: Set<String> = Set("""
        a i an as at be by do go he if in is it me my no of on or so to up us we
        the and for are but not you all any can had her was one our out day get has him his how man new now old see
        two way who did its let put say she too use why yet via per set sum low few end may off own far big top key
        add run map age cut lot ask bad buy fit job law pay try win yes ago due act odd raw tie ten six die ill gun
        that with have this will your from they know want been good much some time very when come here just like
        long make many more only over such take than them well were what also each both does done even give into
        most must same then upon used uses case data high less look mean need next node part path rate real rule
        show side step sure test true unit whom zero four five nine area back best call down drug else ever fact
        feel find form full game gave goes gone half hand hard held help hold idea item keep kind last left life
        line list live lose made main mild move name near note once open plan play poor pool read rest role room
        said seen self sort stay stop talk tell term text thus told tree turn type view wait walk week went word
        work year able away cost door draw edge food free grow link loss meet miss past pick pull push rich rise
        risk save seem send sign size skip slow soon star tend till vote wide wish cure dead sick team age arm
        box car cat dog eye far fun hit hot leg lie men mom oil red sat sea sit son sun war yet own ran got lab
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func split(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\p{L}{5,}"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = String(result[range])
            // The spelling service accepts any word with a capital inside, like "iPhone", so
            // "GettingAround" is split at its capitals before anything is looked up.
            let joinedAtCapital = run.range(of: #"\p{Ll}\p{Lu}"#, options: .regularExpression) != nil
            guard joinedAtCapital || !isWord(run) && !prefixed(run) else { continue }
            // Capitals mark word starts first: "countsinTable" is "countsin" and "Table".
            let parts = camelParts(run).map { part in
                isWord(part) || isAcronym(part) || part.count < 2 ? part : (pieces(of: part)?.joined(separator: " ") ?? part)
            }
            let split = parts.joined(separator: " ")
            if split != run { result.replaceSubrange(range, with: split) }
        }
        return result
    }

    /// A word the dictionary lacks but builds from a prefix, as "hyperparameters" or
    /// "Metalearners", is one word, not "hyper parameters" or "Metal earners".
    static func prefixed(_ run: String) -> Bool {
        let lower = run.lowercased()
        return ["hyper", "meta", "multi", "inter", "intra", "super", "sub", "semi", "pseudo", "non", "pre", "post", "auto", "self", "co", "re", "un", "over", "under", "counter", "cross", "micro", "macro", "mini"]
            .contains { lower.hasPrefix($0) && lower.count - $0.count >= 4 && isWord(String(lower.dropFirst($0.count))) }
    }

    /// Splits before a capital that follows a lowercase letter, and where a run of capitals
    /// meets lowercase letters: "nodeDAGwhere" gives "node", "DAG" and "where", while
    /// "AComplete" gives "A" and "Complete". The dictionary decides which capital starts the word.
    private static func camelParts(_ run: String) -> [String] {
        let letters = Array(run)
        var cuts: [Int] = []
        for index in 1..<max(letters.count, 1) {
            let previous = letters[index - 1], letter = letters[index]
            if previous.isLowercase && letter.isUppercase {
                cuts.append(index)
            } else if previous.isUppercase && letter.isLowercase && index >= 2 && letters[index - 2].isUppercase {
                let tail = String(letters[index...].prefix { $0.isLowercase })
                let withCapital = String(previous) + tail
                let rest = String(tail.dropFirst())
                if tail.hasPrefix("s"), !rest.isEmpty, commonWords.contains(rest) || isWord(rest) {
                    // A plural acronym: "ITEsand" is "ITEs and".
                    cuts.append(index + 1)
                } else {
                    cuts.append(isWord(withCapital) || !isWord(tail) ? index - 1 : index)
                }
            }
        }
        var parts: [String] = []
        var start = 0
        for cut in cuts where cut > start {
            parts.append(String(letters[start..<cut]))
            start = cut
        }
        parts.append(String(letters[start...]))
        return parts.filter { !$0.isEmpty }
    }

    private static func isAcronym(_ part: String) -> Bool {
        part.count >= 2 && part.count <= 6 && part.allSatisfy(\.isUppercase)
    }

    /// The fewest dictionary words that make up `run`, preferring common words.
    private static func pieces(of run: String) -> [String]? {
        let letters = Array(run)
        typealias Split = (words: [String], common: Int)
        var best = [Split?](repeating: nil, count: letters.count + 1)
        best[0] = ([], 0)
        for end in 1...letters.count {
            for start in max(0, end - 24)..<end {
                guard let prefix = best[start], prefix.words.count < max(5, letters.count / 3) else { continue }
                let piece = String(letters[start..<end])
                // The pronoun is always a capital; a lone "i" is a fragment, as in "Markov i an".
                let common = commonWords.contains(piece.lowercased()) && piece != "i"
                guard piece.count > 4 ? isWord(piece) || isAcronym(piece) : common else { continue }
                let candidate: Split = (prefix.words + [piece], prefix.common + (common ? 1 : 0))
                if let current = best[end] {
                    if better(candidate, than: current) { best[end] = candidate }
                } else {
                    best[end] = candidate
                }
            }
        }
        guard let found = best[letters.count], found.words.count > 1 else { return nil }
        // A capitalised run under nine letters is often a name ("Hastie", "Berkson"); it only
        // loses a joining word from its end, as in "Proofof" or "Whyto".
        if let first = run.first, first.isUppercase, run.count < 9 {
            guard found.words.count == 2, found.words[0].count >= 3, joiningWords.contains(found.words[1]) else { return nil }
        }
        return found.words
    }

    private static let joiningWords: Set<String> = ["of", "to", "in", "and", "is", "for", "the", "with", "as"]

    /// Words of machine learning and computing the spelling dictionary lacks; a split that finds
    /// one wins, so "theseshardings" is "these shardings", not "theses hardings".
    private static let technicalWords: Set<String> = Set("""
        shard shards sharded sharding shardings unsharded matmul matmuls allgather allreduce reducescatter alltoall
        dataset datasets runtime runtimes tokenizer tokenizers prefill backprop dropout softmax layernorm
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Fewer words first, then more common words, then the more even split, so
    /// "areconditioned" is "are conditioned" rather than "a reconditioned".
    private static func better(_ candidate: (words: [String], common: Int), than current: (words: [String], common: Int)) -> Bool {
        if candidate.words.count != current.words.count { return candidate.words.count < current.words.count }
        func technical(_ words: [String]) -> Int { words.filter { technicalWords.contains($0.lowercased()) }.count }
        if technical(candidate.words) != technical(current.words) { return technical(candidate.words) > technical(current.words) }
        if candidate.common != current.common { return candidate.common > current.common }
        func spread(_ words: [String]) -> Int { words.reduce(0) { $0 + $1.count * $1.count } }
        return spread(candidate.words) < spread(current.words)
    }

    /// The spelling service can pass every word while its dictionary still loads; it is asked about
    /// a word that is none until it says so, once, so every answer after comes from the dictionary.
    nonisolated(unsafe) private static var warmed = false
    private static func ready() {
        guard !warmed else { return }
        warmed = true
        for _ in 0..<200 {
            if NSSpellChecker.shared.checkSpelling(of: "qzxvbn", startingAt: 0, language: "en", wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func isWord(_ word: String) -> Bool {
        // Ligatures such as "ﬀ" are spelled out before checking.
        let plain = word.precomposedStringWithCompatibilityMapping
        if technicalWords.contains(plain.lowercased()) { return true }
        lock.lock()
        if let cached = known[plain] { lock.unlock(); return cached }
        lock.unlock()
        let check = {
            ready()
            return NSSpellChecker.shared.checkSpelling(of: plain, startingAt: 0, language: "en", wrap: false,
                                                       inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        // The spelling service expects the main thread.
        let valid = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        lock.lock()
        known[plain] = valid
        lock.unlock()
        return valid
    }
}
