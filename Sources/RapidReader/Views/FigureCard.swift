import AppKit
import RapidReaderCore
import SwiftUI

/// Shows a formula, code listing or image from the source page while playback waits for the reader.
struct FigureCard: View {
    let figure: SectionFigure
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Label(figure.kind.title, systemImage: figure.kind.symbolName)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.readerAmberText)

            if let image = NSImage.figure(figure) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .interpolation(.high)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(18)
                }
                .scrollIndicators(.automatic)
                .fixedSize(horizontal: false, vertical: image.size.height < 420)
                .frame(maxWidth: min(image.size.width + 36, 980))
                // Page crops keep the paper colour so they read the same in every theme.
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                .accessibilityLabel(figure.text.isEmpty ? figure.kind.title : figure.text)
            } else if !figure.text.isEmpty {
                // Shown when the source could not be rendered, for example a page that failed to load.
                ScrollView([.vertical, .horizontal]) {
                    Text(figure.text)
                        .font(.system(size: 15, design: figure.kind == .formula ? .serif : .monospaced))
                        .foregroundStyle(.black)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(maxWidth: 980, maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            }

            Button(action: onContinue) {
                Label("Continue reading", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.readerAmber)
            .controlSize(.large)
            .help("Continue reading (Space)")

            Text("Playback waits here until you continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("rsvp-figure")
    }
}

extension SectionFigure.Kind {
    var symbolName: String {
        switch self {
        case .formula: "function"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .table: "tablecells"
        }
    }
}

extension NSImage {
    /// Figure crops are rendered at two to three times page size; showing them at half
    /// their pixel size keeps them a little larger than on paper and still sharp.
    static func figure(_ figure: SectionFigure) -> NSImage? {
        guard let image = NSImage(data: figure.imageData), let rep = image.representations.first else { return nil }
        image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        return image
    }
}
