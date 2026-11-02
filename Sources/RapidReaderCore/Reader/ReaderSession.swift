import Combine
import Foundation

/// Reading state and RSVP playback for one document.
///
/// Tokens are computed once per section and cached, and playback waits on absolute
/// deadlines so rounding errors never accumulate into a slower real speed.
@MainActor
public final class ReaderSession: ObservableObject {
    public let sections: [BookSection]

    @Published public private(set) var sectionIndex: Int
    @Published public private(set) var wordIndex: Int
    @Published public private(set) var isPlaying = false
    /// A formula, code listing or image playback stopped at. Playback continues only once
    /// the reader is done with it and plays again.
    @Published public private(set) var presentedFigure: SectionFigure?
    /// Playback stopped on a longer inline expression and waits for the reader to continue.
    @Published public private(set) var isHoldingExpression = false
    /// Playback has paused to ask whether the reader is still following.
    @Published public private(set) var isCheckingIn = false
    @Published public var preferences: ReadingPreferences {
        didSet {
            let clamped = preferences.clamped()
            if clamped != preferences {
                preferences = clamped
            }
        }
    }

    /// Words of the current section.
    public private(set) var words: [String] = []

    /// Called with `(sectionIndex, wordIndex)` whenever progress should be persisted.
    public var onProgressChange: ((Int, Int) -> Void)?

    /// Called with `(words, seconds)` for each playback run when it stops.
    /// Words count once their display time has fully elapsed.
    public var onReadingSegment: ((Int, TimeInterval) -> Void)?

    private var playbackStartedAt: ContinuousClock.Instant?
    private var shouldRewindOnResume = false
    private var finishedFigure: UUID?
    /// Figures after a section's last word, as a display that ends a proof, are shown before
    /// moving on; these have been shown in the current section.
    private var shownClosingFigures: Set<UUID> = []
    private var closingFigure: SectionFigure?
    private var finishedExpression: (section: Int, start: Int)?
    private var expressionCache: [Int: [Range<Int>]] = [:]
    private var segmentWords = 0
    private var playedSinceCheckIn: TimeInterval = 0
    private var tokenCache: [Int: [String]] = [:]
    private var pacingCache: (key: PacingKey, value: Double)?
    private var playbackTask: Task<Void, Never>?
    private var lastProgressReport = ContinuousClock.now
    private let progressReportInterval: Duration
    private let clock = ContinuousClock()

    public init(
        sections: [BookSection],
        sectionIndex: Int = 0,
        wordIndex: Int = 0,
        preferences: ReadingPreferences = ReadingPreferences(),
        progressReportInterval: Duration = .seconds(1)
    ) {
        self.sections = sections
        self.preferences = preferences.clamped()
        self.progressReportInterval = progressReportInterval
        self.sectionIndex = min(max(sectionIndex, 0), max(sections.count - 1, 0))
        self.wordIndex = 0
        self.words = tokens(forSection: self.sectionIndex)
        self.wordIndex = min(max(wordIndex, 0), words.count)
    }

    deinit {
        playbackTask?.cancel()
    }

    public var currentSection: BookSection? {
        sections.indices.contains(sectionIndex) ? sections[sectionIndex] : nil
    }

    public var maxWordIndex: Int {
        max(words.count - 1, 0)
    }

    /// Index of the displayed word, clamped to the section.
    public var displayIndex: Int {
        min(max(wordIndex, 0), maxWordIndex)
    }

    public var displayWords: [String] {
        Array(words[displayRange])
    }

    /// Words shown together: a whole inline expression, or up to `chunkSize` words that
    /// stop short of the next expression.
    public var displayRange: Range<Int> {
        guard !words.isEmpty else { return 0..<0 }
        let start = displayIndex
        if let run = currentExpression { return run }
        var end = min(start + preferences.chunkSize, words.count)
        if let next = expressions.first(where: { $0.lowerBound > start && $0.lowerBound < end }) {
            end = next.lowerBound
        }
        return start..<end
    }

    /// The inline expression at the reading position, if any.
    public var currentExpression: Range<Int>? {
        expressions.first { $0.contains(displayIndex) }
    }

    private var expressions: [Range<Int>] {
        if let cached = expressionCache[sectionIndex] { return cached }
        let runs = TextProcessor.expressionRuns(in: words)
        expressionCache[sectionIndex] = runs
        return runs
    }

    private func isLongExpression(_ run: Range<Int>) -> Bool {
        run.count > 1 || words[run].reduce(0) { $0 + $1.count } >= 10
    }

    public var remainingSectionSeconds: TimeInterval {
        Double(max(0, words.count - wordIndex)) * 60 / Double(preferences.wordsPerMinute)
    }

    public var remainingBookSeconds: TimeInterval {
        let laterWords = sections.dropFirst(sectionIndex + 1).reduce(0) { $0 + $1.wordCount }
        return remainingSectionSeconds + Double(laterWords) * 60 / Double(preferences.wordsPerMinute)
    }

    public var isAtEnd: Bool {
        sectionIndex >= sections.count - 1 && wordIndex >= words.count
    }

    public func tokens(forSection index: Int) -> [String] {
        if let cached = tokenCache[index] {
            return cached
        }
        guard sections.indices.contains(index) else { return [] }
        let tokens = TextProcessor.tokenize(sections[index].text)
        tokenCache[index] = tokens
        return tokens
    }

    // MARK: Playback

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard !isPlaying else { return }
        isCheckingIn = false
        if let figure = presentedFigure {
            finishedFigure = figure.id
            presentedFigure = nil
            shouldRewindOnResume = false
        } else if presentFigureIfNeeded() {
            return
        }
        if isHoldingExpression {
            // The expression has been read; carry on with what follows it.
            isHoldingExpression = false
            shouldRewindOnResume = false
            if !step(forward: true) { return }
            if presentFigureIfNeeded() || holdOnExpressionIfNeeded() { return }
        } else if let run = currentExpression {
            finishedExpression = (sectionIndex, run.lowerBound)
        }
        if isAtEnd {
            jump(toSection: 0, word: 0)
        } else if shouldRewindOnResume {
            wordIndex = max(0, wordIndex - preferences.resumeRewindWords)
        }
        shouldRewindOnResume = false
        while words.isEmpty, sectionIndex + 1 < sections.count {
            moveToSection(sectionIndex + 1)
            wordIndex = 0
        }
        guard !words.isEmpty else { return }
        playbackStartedAt = clock.now
        segmentWords = 0
        isPlaying = true
        playbackTask?.cancel()
        let clock = self.clock
        playbackTask = Task { [weak self] in
            var deadline = clock.now
            while !Task.isCancelled {
                guard let duration = self?.currentDisplayDuration(), self?.isPlaying == true else { return }
                deadline = deadline.advanced(by: .seconds(duration))
                if clock.now - deadline > .seconds(1) {
                    deadline = clock.now.advanced(by: .seconds(duration))
                }
                do {
                    try await clock.sleep(until: deadline, tolerance: .milliseconds(2))
                } catch { return }
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                self.segmentWords += self.displayWords.count
                self.playedSinceCheckIn += duration
                if !self.step(forward: true) {
                    self.pause()
                } else if self.presentFigureIfNeeded() || self.holdOnExpressionIfNeeded() || self.checkInIfDue() {
                    return
                }
            }
        }
    }

    public func pause() {
        if isPlaying {
            shouldRewindOnResume = true
            if let start = playbackStartedAt {
                onReadingSegment?(segmentWords, start.duration(to: clock.now).secondsValue)
            }
            segmentWords = 0
        }
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        reportProgress(force: true)
    }

    /// The first unread figure placed before one of the displayed words.
    public var figureAtPosition: SectionFigure? {
        guard let section = currentSection, !words.isEmpty else { return nil }
        let range = displayIndex..<(displayIndex + max(displayWords.count, 1))
        return section.figures.first { range.contains($0.wordIndex) && $0.id != finishedFigure }
    }

    /// Stops playback on a figure so it can be read at the reader's own pace.
    private func presentFigureIfNeeded() -> Bool {
        if let figure = closingFigure {
            closingFigure = nil
            pause()
            shouldRewindOnResume = false
            presentedFigure = figure
            return true
        }
        guard let figure = figureAtPosition else { return false }
        pause()
        shouldRewindOnResume = false
        presentedFigure = figure
        return true
    }

    private func holdOnExpressionIfNeeded() -> Bool {
        guard preferences.stopOnExpressions, let run = currentExpression, isLongExpression(run) else { return false }
        if let finished = finishedExpression, finished.section == sectionIndex, finished.start == run.lowerBound { return false }
        pause()
        shouldRewindOnResume = false
        finishedExpression = (sectionIndex, run.lowerBound)
        isHoldingExpression = true
        return true
    }

    /// Shows a figure without playing, for example from the figure list.
    public func showFigure(_ figure: SectionFigure) {
        pause()
        presentedFigure = figure
    }

    /// Pauses for a check-in once enough reading time has passed, at the end of a sentence
    /// unless none comes within half a minute.
    private func checkInIfDue() -> Bool {
        let interval = Double(preferences.checkInMinutes) * 60
        guard interval > 0, playedSinceCheckIn >= interval, currentExpression == nil else { return false }
        let endedSentence = words.indices.contains(wordIndex - 1) && RSVPWord(words[wordIndex - 1]).endsSentence
        guard endedSentence || playedSinceCheckIn >= interval + 30 else { return false }
        pause()
        shouldRewindOnResume = false
        playedSinceCheckIn = 0
        isCheckingIn = true
        return true
    }

    /// Answers a check-in with "I drifted": goes back about half a minute of reading, to the
    /// start of a sentence, and plays from there.
    public func rewindAfterCheckIn() {
        let start = max(0, wordIndex - max(1, preferences.wordsPerMinute / 2))
        var target = start
        while target > 0 && start - target < 60 && !RSVPWord(words[target - 1]).endsSentence {
            target -= 1
        }
        if target > 0, !RSVPWord(words[target - 1]).endsSentence { target = start }
        jump(toSection: sectionIndex, word: target)
        play()
    }

    public func dismissFigure() {
        if let figure = presentedFigure { finishedFigure = figure.id }
        presentedFigure = nil
    }

    /// How long the currently displayed chunk stays on screen.
    public func currentDisplayDuration() -> TimeInterval {
        let elapsed = playbackStartedAt.map { $0.duration(to: clock.now).secondsValue } ?? 0
        let duration = RSVPTiming.displayDuration(for: displayWords, preferences: preferences, elapsed: elapsed, pacing: sectionPacing)
        // Expressions are denser than words, so even short ones stay up twice as long.
        return currentExpression == nil ? duration : duration * 2
    }

    private struct PacingKey: Equatable {
        var section: Int
        var chunkSize: Int
        var punctuation: Bool
        var longWords: Bool
    }

    /// Average pause multiplier of the current section, cached until the section or pause settings change.
    private var sectionPacing: Double {
        let key = PacingKey(section: sectionIndex, chunkSize: preferences.chunkSize, punctuation: preferences.pauseOnPunctuation, longWords: preferences.pauseOnLongWords)
        if let cached = pacingCache, cached.key == key { return cached.value }
        let value = RSVPTiming.pacing(for: words, preferences: preferences)
        pacingCache = (key, value)
        return value
    }

    // MARK: Navigation

    /// Goes to the start of the next sentence, or of the next section. Playback carries on if it was running.
    public func forward() {
        let wasPlaying = isPlaying
        defer { if wasPlaying { play() } }
        pause()
        presentedFigure = nil
        isHoldingExpression = false
        isCheckingIn = false
        shouldRewindOnResume = false
        if let next = sentenceStart(after: wordIndex) {
            wordIndex = next
        } else if sectionIndex + 1 < sections.count {
            moveToSection(sectionIndex + 1)
            wordIndex = 0
        } else {
            wordIndex = words.count
        }
        reportProgress(force: true)
    }

    /// Goes to the start of the current sentence, or of the one before when the current one
    /// has only just begun, so pressing again keeps stepping back a sentence at a time.
    /// Playback carries on if it was running.
    public func back() {
        let wasPlaying = isPlaying
        defer { if wasPlaying { play() } }
        pause()
        presentedFigure = nil
        isHoldingExpression = false
        isCheckingIn = false
        shouldRewindOnResume = false
        var start = sentenceStart(atOrBefore: wordIndex)
        if wordIndex - start <= 2 {
            if start > 0 {
                start = sentenceStart(atOrBefore: start - 1)
            } else if sectionIndex > 0 {
                moveToSection(sectionIndex - 1)
                start = sentenceStart(atOrBefore: maxWordIndex)
            }
        }
        wordIndex = snappedToExpression(start)
        reportProgress(force: true)
    }

    private func sentenceStart(atOrBefore index: Int) -> Int {
        var start = min(max(index, 0), words.count)
        while start > 0, !RSVPWord(words[start - 1]).endsSentence {
            start -= 1
        }
        return start
    }

    private func sentenceStart(after index: Int) -> Int? {
        var next = index + 1
        while next < words.count {
            if RSVPWord(words[next - 1]).endsSentence { return snappedToExpression(next) }
            next += 1
        }
        return nil
    }

    private func snappedToExpression(_ index: Int) -> Int {
        expressions.first { $0.contains(index) }?.lowerBound ?? index
    }

    public func goToSection(_ index: Int) {
        pause()
        jump(toSection: index, word: 0)
    }

    public func setWordIndex(_ index: Int) {
        pause()
        presentedFigure = nil
        isHoldingExpression = false
        isCheckingIn = false
        shouldRewindOnResume = false
        wordIndex = min(max(index, 0), maxWordIndex)
        reportProgress(force: true)
    }

    public func jump(toSection section: Int, word: Int) {
        pause()
        presentedFigure = nil
        isHoldingExpression = false
        isCheckingIn = false
        shouldRewindOnResume = false
        moveToSection(section)
        wordIndex = min(max(word, 0), maxWordIndex)
        // A jump lands on a word the reader picked, so a figure just before it is not shown again.
        finishedFigure = figureAtPosition?.id
        reportProgress(force: true)
    }

    /// Moves one chunk forward or backward. Returns `false` when the end of the document was reached.
    @discardableResult
    private func step(forward: Bool) -> Bool {
        let step = preferences.chunkSize
        if forward {
            let next = displayRange.upperBound
            if next > wordIndex, next < words.count {
                wordIndex = next
            } else if let figure = currentSection?.figures.first(where: { $0.wordIndex >= words.count && !shownClosingFigures.contains($0.id) }) {
                shownClosingFigures.insert(figure.id)
                closingFigure = figure
            } else if sectionIndex + 1 < sections.count {
                moveToSection(sectionIndex + 1)
                wordIndex = 0
            } else {
                wordIndex = words.count
                reportProgress(force: true)
                return false
            }
        } else {
            if wordIndex - step >= 0 {
                let target = min((currentExpression?.lowerBound ?? wordIndex) - step, maxWordIndex)
                wordIndex = max(0, expressions.first { $0.contains(target) }?.lowerBound ?? target)
            } else if sectionIndex > 0 {
                moveToSection(sectionIndex - 1)
                wordIndex = maxWordIndex
            } else {
                wordIndex = 0
            }
        }
        reportProgress(force: false)
        return true
    }

    private func moveToSection(_ index: Int) {
        let clamped = min(max(index, 0), max(sections.count - 1, 0))
        if clamped != sectionIndex || words.isEmpty {
            sectionIndex = clamped
            words = tokens(forSection: clamped)
            shownClosingFigures = []
            closingFigure = nil
        }
    }

    private func reportProgress(force: Bool) {
        let now = clock.now
        guard force || now - lastProgressReport >= progressReportInterval else { return }
        lastProgressReport = now
        onProgressChange?(sectionIndex, wordIndex)
    }
}

public enum RSVPTiming {
    /// Seconds a chunk of words stays on screen at the given preferences.
    ///
    /// Pauses on punctuation and long words are divided by `pacing`, the average pause of the
    /// text, so they share out reading time instead of adding to it and the text as a whole
    /// is read at the chosen words per minute.
    public static func displayDuration(for words: [String], preferences: ReadingPreferences, elapsed: TimeInterval = .infinity, pacing: Double = 1) -> TimeInterval {
        let preferences = preferences.clamped()
        let chunk = max(words.count, 1)
        var duration = 60.0 * Double(chunk) / Double(preferences.wordsPerMinute)
        duration *= pauseMultiplier(for: words, preferences: preferences) / max(pacing, 0.01)
        if preferences.rampUpSeconds > 0 {
            let fraction = min(1, max(0, elapsed / preferences.rampUpSeconds))
            duration /= 0.5 + 0.5 * fraction
        }
        return duration
    }

    /// Average pause multiplier over `words` read in chunks, weighted by chunk length.
    public static func pacing(for words: [String], preferences: ReadingPreferences) -> Double {
        let preferences = preferences.clamped()
        guard !words.isEmpty, preferences.pauseOnPunctuation || preferences.pauseOnLongWords else { return 1 }
        var total = 0.0
        for start in stride(from: 0, to: words.count, by: preferences.chunkSize) {
            let chunk = Array(words[start..<min(start + preferences.chunkSize, words.count)])
            total += Double(chunk.count) * pauseMultiplier(for: chunk, preferences: preferences)
        }
        return total / Double(words.count)
    }

    private static func pauseMultiplier(for words: [String], preferences: ReadingPreferences) -> Double {
        var multiplier = 1.0
        if preferences.pauseOnPunctuation, let last = words.last {
            multiplier *= RSVPWord(last).punctuationDelayMultiplier
        }
        if preferences.pauseOnLongWords {
            multiplier *= words.map { RSVPWord($0).lengthDelayMultiplier }.max() ?? 1
        }
        return multiplier
    }
}

extension Duration {
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
