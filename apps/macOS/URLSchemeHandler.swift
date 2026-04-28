import Foundation
import os.log

#if os(macOS)
import AppKit
#endif

/// Handles `paperless-clipper://render?jobId=<uuid>` from the extension's
/// custom URL scheme launch.
///
/// Reads the cached HTML, renders it to PDF via WKWebView.createPDF,
/// uploads the PDF to Paperless via the user's API token, and updates
/// the App Group job record with terminal state.
@MainActor
public final class URLSchemeHandler {

    private let log = Logger(subsystem: "org.czei.PaperlessClipper", category: "url-scheme")
    private let jobStore = JobStore()
    private let paperless = PaperlessClient()

    public static let shared = URLSchemeHandler()

    public func handle(url: URL) {
        guard url.scheme == "paperless-clipper", url.host == "render" else {
            log.error("ignoring URL: \(url.absoluteString, privacy: .public)")
            return
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let jobId = comps.queryItems?.first(where: { $0.name == "jobId" })?.value else {
            log.error("missing jobId in URL: \(url.absoluteString, privacy: .public)")
            return
        }
        Task { await self.handleJob(jobId: jobId) }
    }

    private func handleJob(jobId: String) async {
        log.info("handling job \(jobId, privacy: .public)")

        // Read the HTML from App Group UserDefaults (not from a shared file).
        // macOS 15+ prompts on cross-app file access in App Group containers;
        // UserDefaults is the documented shared-state path that doesn't.
        guard let defaults = AppGroup.defaults,
              let html = defaults.string(forKey: "jobHtml.\(jobId)") else {
            log.error("HTML payload missing for job \(jobId, privacy: .public)")
            await markFailed(jobId: jobId, kind: .cancelled, message: "Capture data missing")
            return
        }

        guard var record = try? jobStore.load(jobId: jobId) else {
            log.error("no JobRecord for job \(jobId, privacy: .public)")
            return
        }

        // Stage 1: render PDF
        record.state = .rendering
        try? jobStore.save(record)

        let pdf: Data
        do {
            let rawPDF = try await PDFRenderer().renderHTML(html)
            pdf = PDFRenderer.annotateSourceURL(rawPDF, sourceURL: record.sourceURL)
            log.info("rendered PDF: \(pdf.count) bytes for job \(jobId, privacy: .public)")
        } catch {
            log.error("render failed: \(error.localizedDescription, privacy: .public)")
            await markFailed(jobId: jobId, kind: .unknown, message: "Render failed: \(error.localizedDescription)")
            return
        }

        // Stage 2: upload to Paperless
        record.state = .uploading
        try? jobStore.save(record)

        guard let serverURL = await loadServerURLForUpload() else {
            await markFailed(jobId: jobId, kind: .notConfigured, message: "Paperless server URL not configured.")
            return
        }

        do {
            let result = try await paperless.upload(
                pdfData: pdf,
                serverURL: serverURL,
                title: record.title,
                sourceURL: record.sourceURL,
                capturedAt: record.capturedAt
            )
            log.info("uploaded job \(jobId, privacy: .public); paperless task id=\(result.serverTaskId, privacy: .public)")
            await markSucceeded(jobId: jobId, serverTaskId: result.serverTaskId)
        } catch let err as PaperlessClient.ClientError {
            let (kind, message) = mapClientError(err)
            log.error("upload failed: \(message, privacy: .public)")
            await markFailed(jobId: jobId, kind: kind, message: message)
        } catch {
            log.error("upload failed (generic): \(error.localizedDescription, privacy: .public)")
            await markFailed(jobId: jobId, kind: .unknown, message: error.localizedDescription)
        }

        // Stage 3: cleanup HTML payload regardless of outcome.
        defaults.removeObject(forKey: "jobHtml.\(jobId)")
        defaults.removeObject(forKey: "jobInit.\(jobId)")
    }

    private func loadServerURLForUpload() async -> URL? {
        // The JS layer wrote `serverURL` into `browser.storage.local`, but
        // App Group UserDefaults also has it via the chunked init payload
        // (jobInit.<jobId>). For the prototype we read from the jobInit
        // record. Future Settings UI will write to AppGroup.defaults
        // directly under "serverURL".
        guard let defaults = AppGroup.defaults else { return nil }
        // First try the per-job stash (always written at init time).
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("jobInit.") {
            if let dict = defaults.dictionary(forKey: key),
               let s = dict["serverURL"] as? String,
               let u = URL(string: s) {
                return u
            }
        }
        // Fall through to a globally-stored serverURL when settings UI lands.
        if let s = defaults.string(forKey: "serverURL"), let u = URL(string: s) {
            return u
        }
        return nil
    }

    private func mapClientError(_ err: PaperlessClient.ClientError) -> (ErrorKind, String) {
        switch err {
        case .missingToken:
            return (.notConfigured, "API token not stored. Save it from settings.")
        case .httpsRequired:
            return (.httpsRequired, "Paperless server URL must use HTTPS.")
        case .authRejected(let msg):
            return (.authRejected, msg.isEmpty ? "Paperless rejected the API token." : msg)
        case .tooLarge(let msg):
            return (.tooLarge, msg.isEmpty ? "PDF is too large for Paperless." : msg)
        case .rejectedByServer(let status, let body):
            return (.serverRejectedUpload, "HTTP \(status): \(body.prefix(200))")
        case .network(let nerr):
            return (.cannotReachServer, nerr.localizedDescription)
        case .unknown(let msg):
            return (.unknown, msg)
        }
    }

    private func markSucceeded(jobId: String, serverTaskId: String) async {
        guard var record = try? jobStore.load(jobId: jobId) else { return }
        record.state = .succeeded
        record.completedAt = Date()
        record.serverTaskId = serverTaskId
        try? jobStore.save(record)
    }

    private func markFailed(jobId: String, kind: ErrorKind, message: String) async {
        guard var record = try? jobStore.load(jobId: jobId) else { return }
        record.state = .failed
        record.failedAt = Date()
        record.errorKind = kind
        record.message = message
        try? jobStore.save(record)
    }
}
