import AppKit
import Foundation
import UniformTypeIdentifiers

public enum DocumentImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadableFile(String)
    case emptyDocument(String)
    case invalidURL(String)
    case networkFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            "Unsupported format: \(name)"
        case .unreadableFile(let name):
            "Could not read \(name)."
        case .emptyDocument(let name):
            "\(name) does not contain readable text."
        case .invalidURL(let value):
            "\(value) is not a valid URL."
        case .networkFailure(let message):
            message
        }
    }
}

public final class DocumentImportService: Sendable {
    public static let supportedFileTypes: [UTType] = [
        .pdf,
        .plainText,
        .text,
        .utf8PlainText,
        .rtf,
        .html,
        UTType(filenameExtension: "epub") ?? .data,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "md") ?? .data,
        UTType(filenameExtension: "markdown") ?? .data
    ]

    public init() {}

    public func importFile(at url: URL) async throws -> ImportedDocument {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "epub":
            return try EPUBParser.importEPUB(at: url)
        case "pdf":
            return try PDFTextExtractor.importPDF(at: url)
        case "docx":
            return try DOCXParser.importDOCX(at: url)
        case "rtf", "rtfd":
            return try importAttributedText(at: url, format: .rtf)
        case "html", "htm", "xhtml":
            return try await importHTMLFile(at: url)
        case "md", "markdown":
            return try importPlainTextFile(at: url, format: .markdown)
        case "txt", "text":
            return try importPlainTextFile(at: url, format: .plainText)
        default:
            if let imported = try? importPlainTextFile(at: url, format: .unknown) {
                return imported
            }
            throw DocumentImportError.unsupportedFormat(url.lastPathComponent)
        }
    }

    public func importClipboardText(_ text: String) throws -> ImportedDocument {
        let normalized = TextProcessor.normalizedText(text)
        guard !TextProcessor.tokenize(normalized).isEmpty else {
            throw DocumentImportError.emptyDocument("Clipboard")
        }
        let firstLine = normalized.components(separatedBy: .newlines).first ?? "Clipboard Text"
        let title = String(firstLine.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression).prefix(80))
        return ImportedDocument(
            title: title,
            sourceName: "Clipboard",
            format: .plainText,
            sections: TextProcessor.sections(from: normalized, fallbackTitle: title)
        )
    }

    public func importArticle(from url: URL) async throws -> ImportedDocument {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw DocumentImportError.invalidURL(url.absoluteString)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw DocumentImportError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocumentImportError.networkFailure("The server returned HTTP \(http.statusCode).")
        }

        let html = HTMLTextExtractor.decode(data)
        let title = TextProcessor.cleanedTitle(
            HTMLTextExtractor.title(fromHTML: html),
            fallback: url.host(percentEncoded: false) ?? "Web Article"
        )
        let sections = await Self.htmlSections(html, baseURL: url, article: true, title: title)
        guard sections.contains(where: { $0.wordCount > 0 }) else {
            throw DocumentImportError.emptyDocument(url.absoluteString)
        }

        return ImportedDocument(
            title: title,
            sourceName: url.absoluteString,
            sourceURL: url.absoluteString,
            format: .webArticle,
            sections: sections
        )
    }

    /// Reading sections for a page, with its figures, code, tables and equations rendered as pictures.
    private static func htmlSections(_ html: String, baseURL: URL, article: Bool, title: String) async -> [BookSection] {
        guard let extraction = WebArticleExtractor.extract(html, article: article) else { return [] }
        let images = await WebSnapshotter.render(html: extraction.renderHTML, baseURL: baseURL, requests: extraction.requests)
        return WebArticleExtractor.sections(from: extraction, images: images, fallbackTitle: title)
    }

    private func importPlainTextFile(at url: URL, format: ReadingFormat) throws -> ImportedDocument {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .macOSRoman)
            ?? ""
        let normalized = TextProcessor.normalizedText(text)
        guard !normalized.isEmpty else {
            throw DocumentImportError.emptyDocument(url.lastPathComponent)
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return ImportedDocument(
            title: fallbackTitle,
            sourceName: url.lastPathComponent,
            sourceURL: url.absoluteString,
            format: format,
            sections: TextProcessor.sections(from: normalized, fallbackTitle: fallbackTitle)
        )
    }

    private func importHTMLFile(at url: URL) async throws -> ImportedDocument {
        let data = try Data(contentsOf: url)
        let html = HTMLTextExtractor.decode(data)
        let title = TextProcessor.cleanedTitle(
            HTMLTextExtractor.title(fromHTML: html),
            fallback: url.deletingPathExtension().lastPathComponent
        )
        let sections = await Self.htmlSections(html, baseURL: url.deletingLastPathComponent(), article: false, title: title)
        guard sections.contains(where: { $0.wordCount > 0 }) else {
            throw DocumentImportError.emptyDocument(url.lastPathComponent)
        }

        return ImportedDocument(
            title: title,
            sourceName: url.lastPathComponent,
            sourceURL: url.absoluteString,
            format: .html,
            sections: sections
        )
    }

    private func importAttributedText(at url: URL, format: ReadingFormat) throws -> ImportedDocument {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let text = TextProcessor.normalizedText(attributed.string)
        guard !text.isEmpty else {
            throw DocumentImportError.emptyDocument(url.lastPathComponent)
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return ImportedDocument(
            title: fallbackTitle,
            sourceName: url.lastPathComponent,
            sourceURL: url.absoluteString,
            format: format,
            sections: TextProcessor.sections(from: text, fallbackTitle: fallbackTitle)
        )
    }

}
