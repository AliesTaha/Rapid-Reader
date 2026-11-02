import Foundation

public struct ReadingPreferences: Codable, Equatable, Sendable {
    public var wordsPerMinute: Int
    public var fontSize: Double
    public var chunkSize: Int
    public var showContext: Bool
    public var pauseOnPunctuation: Bool
    public var focusMode: Bool
    public var rampUpSeconds: Double
    public var pauseOnLongWords: Bool
    public var resumeRewindWords: Int
    /// Playback stops on longer inline expressions until the reader continues.
    public var stopOnExpressions: Bool
    /// Minutes of playback between "still with me?" check-ins; 0 turns them off.
    public var checkInMinutes: Int
    /// A thin progress bar and time left in the section stay visible while reading.
    public var showSectionProgress: Bool
    /// The focus letter pulses on each new word, giving the eye a beat to follow.
    public var rhythmPulse: Bool

    public init(
        wordsPerMinute: Int = 350,
        fontSize: Double = 72,
        chunkSize: Int = 1,
        showContext: Bool = true,
        pauseOnPunctuation: Bool = true,
        focusMode: Bool = false,
        rampUpSeconds: Double = 0,
        pauseOnLongWords: Bool = true,
        resumeRewindWords: Int = 0,
        stopOnExpressions: Bool = true,
        checkInMinutes: Int = 4,
        showSectionProgress: Bool = true,
        rhythmPulse: Bool = true
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.fontSize = fontSize
        self.chunkSize = chunkSize
        self.showContext = showContext
        self.pauseOnPunctuation = pauseOnPunctuation
        self.focusMode = focusMode
        self.rampUpSeconds = rampUpSeconds
        self.pauseOnLongWords = pauseOnLongWords
        self.resumeRewindWords = resumeRewindWords
        self.stopOnExpressions = stopOnExpressions
        self.checkInMinutes = checkInMinutes
        self.showSectionProgress = showSectionProgress
        self.rhythmPulse = rhythmPulse
    }

    public func clamped() -> ReadingPreferences {
        var result = self
        result.wordsPerMinute = min(max(wordsPerMinute, 100), 900)
        result.fontSize = fontSize.isFinite ? min(max(fontSize, 42), 110) : 72
        result.chunkSize = min(max(chunkSize, 1), 4)
        result.rampUpSeconds = rampUpSeconds.isFinite ? min(max(rampUpSeconds, 0), 10) : 0
        result.resumeRewindWords = min(max(resumeRewindWords, 0), 20)
        result.checkInMinutes = min(max(checkInMinutes, 0), 30)
        return result
    }

    // Long-word pacing became on by default; a new key lets saved documents pick that up.
    private enum CodingKeys: String, CodingKey {
        case wordsPerMinute, fontSize, chunkSize, showContext, pauseOnPunctuation, focusMode, rampUpSeconds, resumeRewindWords, stopOnExpressions
        case checkInMinutes, showSectionProgress, rhythmPulse
        case pauseOnLongWords = "slowOnLongWords"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReadingPreferences()
        self.init(
            wordsPerMinute: try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? defaults.wordsPerMinute,
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize,
            chunkSize: try container.decodeIfPresent(Int.self, forKey: .chunkSize) ?? defaults.chunkSize,
            showContext: try container.decodeIfPresent(Bool.self, forKey: .showContext) ?? defaults.showContext,
            pauseOnPunctuation: try container.decodeIfPresent(Bool.self, forKey: .pauseOnPunctuation) ?? defaults.pauseOnPunctuation,
            focusMode: try container.decodeIfPresent(Bool.self, forKey: .focusMode) ?? defaults.focusMode,
            rampUpSeconds: try container.decodeIfPresent(Double.self, forKey: .rampUpSeconds) ?? defaults.rampUpSeconds,
            pauseOnLongWords: try container.decodeIfPresent(Bool.self, forKey: .pauseOnLongWords) ?? defaults.pauseOnLongWords,
            resumeRewindWords: try container.decodeIfPresent(Int.self, forKey: .resumeRewindWords) ?? defaults.resumeRewindWords,
            stopOnExpressions: try container.decodeIfPresent(Bool.self, forKey: .stopOnExpressions) ?? defaults.stopOnExpressions,
            checkInMinutes: try container.decodeIfPresent(Int.self, forKey: .checkInMinutes) ?? defaults.checkInMinutes,
            showSectionProgress: try container.decodeIfPresent(Bool.self, forKey: .showSectionProgress) ?? defaults.showSectionProgress,
            rhythmPulse: try container.decodeIfPresent(Bool.self, forKey: .rhythmPulse) ?? defaults.rhythmPulse
        )
    }
}
