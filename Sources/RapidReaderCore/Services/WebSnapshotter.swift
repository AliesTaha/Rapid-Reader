import AppKit
import WebKit

/// Renders a page in a hidden web view and takes pictures of the elements tagged by
/// `WebArticleExtractor`, so figures, code, tables and equations look as they do on the site.
@MainActor
final class WebSnapshotter: NSObject, WKNavigationDelegate {
    private static let width: CGFloat = 960
    private static let viewportHeight: CGFloat = 1200
    private static let maxHeight: CGFloat = 4000

    private let window: NSWindow
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?

    /// PNG data by figure number; figures that could not be rendered are missing.
    static func render(html: String, baseURL: URL?, requests: [Int: WebArticleExtractor.Request]) async -> [Int: Data] {
        guard !requests.isEmpty else { return [:] }
        let snapshotter = WebSnapshotter()
        defer { snapshotter.window.close() }
        await snapshotter.load(html, baseURL: baseURL)
        var images: [Int: Data] = [:]
        for number in requests.keys.sorted() {
            if let data = await snapshotter.snapshot(number, scale: requests[number]?.scale ?? 2) {
                images[number] = data
            }
        }
        return images
    }

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // A hidden window never runs CSS animations, so content that fades in would stay invisible.
        // Fixed headers and banners would cover whatever is scrolled under them.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const style = document.createElement('style');
            style.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; }';
            document.documentElement.appendChild(style);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        window.orderBack(nil)
    }

    private func load(_ html: String, baseURL: URL?) async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishLoading()
            }
        }
        _ = try? await webView.callAsyncJavaScript("""
            const settle = Promise.all([document.fonts.ready, ...[...document.images].map(image => image.complete ? null : new Promise(done => { image.onload = image.onerror = done }))]);
            await Promise.race([settle, new Promise(done => setTimeout(done, 8000))]);
            for (const element of document.querySelectorAll('*')) {
                const position = getComputedStyle(element).position;
                if (position === 'fixed') element.style.visibility = 'hidden';
                if (position === 'sticky') element.style.position = 'static';
            }
            """, contentWorld: .page)
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in finishLoading() }
    }

    private func snapshot(_ number: Int, scale: Double) async -> Data? {
        // Scrolls the element near the top of the view and reports its box in view coordinates.
        let measure = """
            const element = document.querySelector('[\(WebArticleExtractor.figureAttribute)="\(number)"]');
            if (!element) return null;
            window.scrollTo(0, element.getBoundingClientRect().top + window.scrollY - 16);
            await new Promise(done => setTimeout(done, 30));
            // Inline KaTeX reserves a full line box; the drawn parts are its .base spans.
            const parts = element.matches('.katex') && !element.closest('.katex-display') ? [...element.querySelectorAll('.katex-html .base')] : [];
            let box = element.getBoundingClientRect();
            if (parts.length) {
                const rects = parts.map(part => part.getBoundingClientRect()).filter(rect => rect.width > 0);
                if (rects.length) {
                    const left = Math.min(...rects.map(r => r.left)), top = Math.min(...rects.map(r => r.top));
                    const right = Math.max(...rects.map(r => r.right)), bottom = Math.max(...rects.map(r => r.bottom));
                    box = { left, top, width: right - left, height: bottom - top };
                }
            }
            return [box.left, box.top, box.width, box.height];
            """
        guard var box = try? await webView.callAsyncJavaScript(measure, contentWorld: .page) as? [Double], box.count == 4,
              box[2] >= 4, box[3] >= 4 else { return nil }
        let needed = min(Self.maxHeight, max(Self.viewportHeight, box[3] + 48))
        if webView.frame.height != needed {
            window.setContentSize(NSSize(width: Self.width, height: needed))
            webView.frame = NSRect(x: 0, y: 0, width: Self.width, height: needed)
            guard let again = try? await webView.callAsyncJavaScript(measure, contentWorld: .page) as? [Double], again.count == 4 else { return nil }
            box = again
        }
        // Painting can lag behind the scroll in a window that is never shown.
        try? await Task.sleep(for: .milliseconds(120))

        // Inline formulas sit between lines of text, so only blocks get room above and below.
        let pad: Double = scale > 3 ? 3 : 8
        let padY: Double = scale > 3 ? 0 : pad
        var rect = CGRect(x: box[0] - pad, y: box[1] - padY, width: box[2] + pad * 2, height: min(box[3], Self.maxHeight - 48) + padY * 2)
        rect = rect.intersection(webView.bounds)
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        let backing = window.backingScaleFactor
        configuration.snapshotWidth = NSNumber(value: Double(rect.width) * scale / Double(backing))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !isBlank(cgImage) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Elements that did not paint, such as lazy media that never loaded, come out as one colour.
    private func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let first = (pixels[0], pixels[1], pixels[2])
        for index in stride(from: 0, to: side * side * 4, by: 4) where
            abs(Int(pixels[index]) - Int(first.0)) + abs(Int(pixels[index + 1]) - Int(first.1)) + abs(Int(pixels[index + 2]) - Int(first.2)) > 24 {
            return false
        }
        return true
    }
}
