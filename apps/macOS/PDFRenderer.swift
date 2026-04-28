import Foundation
import PDFKit
import WebKit

/// Renders a self-contained HTML blob to a paginated PDF via WKWebView.
///
/// Lives in the containing app (not the extension target) per research R1 —
/// iOS app extensions have memory/process limits that make hosting a
/// `WKWebView` for full-page rendering unreliable. The macOS containing app
/// has plenty of headroom; the iOS containing app does too once woken.
@MainActor
public final class PDFRenderer: NSObject, WKNavigationDelegate {

    public enum RendererError: Error {
        case loadFailed(String)
        case renderFailed(String)
        case timeout
    }

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public override init() {
        // Modern responsive layouts assume a desktop-class viewport. Letter
        // width (816px) collapses Reddit / GitHub / etc. to mobile layouts
        // with broken proportions. 1280px is a typical desktop breakpoint
        // that keeps responsive layouts intact during replay.
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 1024)
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false // snapshot is static; no JS needed
        config.defaultWebpagePreferences = prefs
        self.webView = WKWebView(frame: frame, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    /// Load HTML from a string and produce a PDF. Used when the HTML is
    /// passed via App Group UserDefaults (the macOS 15+-friendly path).
    public func renderHTML(_ html: String, baseURL: URL = URL(string: "about:blank")!) async throws -> Data {
        try await renderInternal(html: html, baseURL: baseURL)
    }

    /// Load the HTML at `htmlURL` (legacy file-based path) and render to PDF.
    /// Kept for the chunked-upload tests; prefer `renderHTML(_:)`.
    public func render(htmlAt htmlURL: URL) async throws -> Data {
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        return try await renderInternal(html: html, baseURL: htmlURL.deletingLastPathComponent())
    }

    private func renderInternal(html: String, baseURL: URL) async throws -> Data {
        try await loadHTML(html, baseURL: baseURL)

        // Ask the page how tall the document body actually is. WKWebView
        // doesn't expose contentSize directly when it's offscreen / not in a
        // window hierarchy, so we go through JavaScript.
        let docHeight = try await evaluateNumber("""
            Math.max(
              document.documentElement.scrollHeight,
              document.body ? document.body.scrollHeight : 0
            )
        """)
        let docWidth = try await evaluateNumber("""
            Math.max(
              document.documentElement.scrollWidth,
              document.body ? document.body.scrollWidth : 0,
              window.innerWidth
            )
        """)

        // Resize the WKWebView so its layout viewport spans the entire page,
        // then give the runloop a moment for re-layout to settle before
        // createPDF reads the geometry.
        let renderWidth = max(CGFloat(docWidth), self.webView.frame.width)
        let renderHeight = max(CGFloat(docHeight), self.webView.frame.height)
        self.webView.frame = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        try? await Task.sleep(nanoseconds: 200_000_000)

        return try await withCheckedThrowingContinuation { continuation in
            let pageRect = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
            let config = WKPDFConfiguration()
            config.rect = pageRect
            self.webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: RendererError.renderFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Evaluate a JS expression that returns a number. Throws if the result
    /// can't be coerced to Double.
    private func evaluateNumber(_ js: String) async throws -> Double {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            self.webView.evaluateJavaScript(js) { value, error in
                if let error = error {
                    continuation.resume(throwing: RendererError.renderFailed(error.localizedDescription))
                    return
                }
                if let n = value as? Double {
                    continuation.resume(returning: n); return
                }
                if let n = value as? Int {
                    continuation.resume(returning: Double(n)); return
                }
                if let n = value as? NSNumber {
                    continuation.resume(returning: n.doubleValue); return
                }
                continuation.resume(throwing: RendererError.renderFailed("evaluateJavaScript returned non-numeric: \(String(describing: value))"))
            }
        }
    }

    private func loadHTML(_ html: String, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            self.webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the layout one runloop tick to settle before we declare ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.loadContinuation?.resume(returning: ())
            self?.loadContinuation = nil
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RendererError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RendererError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }
}

/// WKWebView.scrollView lives on macOS via the embedded NSScrollView.
/// On iOS the API is identical via WKWebView.scrollView (UIScrollView).
/// Bridging here so the call site is platform-uniform.
#if os(macOS)
extension WKWebView {
    var scrollView: NSScrollView {
        // WKWebView wraps its content in NSScrollView. This is the documented
        // way to access scroll metadata on macOS.
        return enclosingScrollView ?? NSScrollView(frame: bounds)
    }
}

extension NSScrollView {
    var contentSize: CGSize {
        return documentView?.frame.size ?? frame.size
    }
}
#endif

/// UIScrollView already has contentSize on iOS; nothing to do.

extension PDFRenderer {

    /// Overlay a clickable link annotation on the source-URL text inside a
    /// PDF produced by `renderHTML`.
    ///
    /// `WKWebView.createPDF` rasterizes `<a href>` elements as plain text —
    /// the anchor doesn't survive into a `PDFAnnotationLink`, so the source
    /// URL printed at the top of every clip looks like a hyperlink but isn't
    /// tappable in any PDF viewer. We compensate by searching for the URL
    /// string in the PDF text stream and adding a link annotation at its
    /// bounds. Long URLs that wrap to multiple lines get one annotation per
    /// line via `selectionsByLine()`.
    ///
    /// Returns the original data unchanged if the URL can't be located or
    /// re-serialization fails — annotation is a best-effort enhancement and
    /// must never block the upload.
    public static func annotateSourceURL(_ pdfData: Data, sourceURL: String) -> Data {
        guard let doc = PDFDocument(data: pdfData),
              let url = URL(string: sourceURL) else {
            return pdfData
        }
        let matches = doc.findString(sourceURL, withOptions: [.caseInsensitive])
        if matches.isEmpty {
            return pdfData
        }
        for match in matches {
            for line in match.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                annotation.url = url
                page.addAnnotation(annotation)
            }
        }
        return doc.dataRepresentation() ?? pdfData
    }
}
