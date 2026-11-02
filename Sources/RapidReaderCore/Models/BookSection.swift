import Foundation

public struct BookSection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var wordCount: Int
    /// Formulas, code and images that RSVP cannot show word by word, in reading order.
    public var figures: [SectionFigure]

    public init(id: UUID = UUID(), title: String, text: String, wordCount: Int? = nil, figures: [SectionFigure] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.wordCount = wordCount ?? TextProcessor.tokenize(text).count
        self.figures = figures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            text: text,
            wordCount: try container.decodeIfPresent(Int.self, forKey: .wordCount),
            figures: try container.decodeIfPresent([SectionFigure].self, forKey: .figures) ?? []
        )
    }

    /// The figure shown just before the word at `wordIndex`, if any.
    public func figure(beforeWord wordIndex: Int) -> SectionFigure? {
        figures.first { $0.wordIndex == wordIndex }
    }
}

/// A region of the source page kept as an image, because it does not read as prose.
public struct SectionFigure: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case formula
        case code
        case image
        case table

        public var title: String {
            switch self {
            case .formula: "Formula"
            case .code: "Code"
            case .image: "Figure"
            case .table: "Table"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Index of the word the figure precedes in the section.
    public var wordIndex: Int
    /// PNG rendering of the region; empty when only the text could be kept.
    public var imageData: Data
    /// Text found inside the region, for search and accessibility.
    public var text: String

    public init(id: UUID = UUID(), kind: Kind, wordIndex: Int, imageData: Data, text: String = "") {
        self.id = id
        self.kind = kind
        self.wordIndex = wordIndex
        self.imageData = imageData
        self.text = text
    }
}
