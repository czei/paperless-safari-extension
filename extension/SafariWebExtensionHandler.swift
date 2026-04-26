import Foundation
import SafariServices
import os.log

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Native bridge for the Safari Web Extension.
///
/// Receives `sendNativeMessage` calls from the JS background script and
/// dispatches on `op`. Intentionally minimal — the bulk of the work
/// (rendering, uploading) lives in the containing app, woken by a custom
/// URL scheme. See `research.md` R1 for why.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private let log = Logger(subsystem: "org.czei.PaperlessClipper", category: "extension")
    private let jobStore = JobStore()
    private let keychain = KeychainStore()

    func beginRequest(with context: NSExtensionContext) {
        guard let inbound = context.inputItems.first as? NSExtensionItem else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "no inbound item"])
            return
        }
        let payload = (inbound.userInfo?[SFExtensionMessageKey] as? [String: Any]) ?? [:]
        let op = (payload["op"] as? String) ?? "<missing>"

        do {
            switch op {
            case "setToken":
                try handleSetToken(payload: payload, context: context)
            case "renderAndUploadOneShot":
                // Single-message variant: init + entire payload + commit + wait
                // for terminal state, all in one native-message round-trip.
                // Used when the serialized HTML fits in one IPC payload —
                // collapses what was 1 init + N chunks + 1 commit + 60 polls
                // into a single privileged Safari boundary crossing.
                try handleRenderOneShot(payload: payload, context: context)
            case "renderAndUpload.init":
                try handleRenderInit(payload: payload, context: context)
            case "renderAndUpload.chunk":
                try handleRenderChunk(payload: payload, context: context)
            case "renderAndUpload.commit":
                try handleRenderCommit(payload: payload, context: context)
            case "waitForJob":
                try handleWaitForJob(payload: payload, context: context)
            case "getJobStatus":
                try handleGetJobStatus(payload: payload, context: context)
            case "revealLastFailure":
                try handleRevealLastFailure(payload: payload, context: context)
            default:
                respond(context: context, with: [
                    "ok": false, "errorKind": "unknown", "message": "unknown op: \(op)",
                ])
            }
        } catch {
            log.error("op \(op, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            respond(context: context, with: [
                "ok": false, "errorKind": "unknown", "message": "\(error)",
            ])
        }
    }

    // MARK: - getToken

    // Note: a getToken op was removed. The containing app reads the
    // Keychain entry directly during upload, which avoids a second
    // "wants to access keychain" prompt on the extension side.

    private func handleSetToken(payload: [String: Any], context: NSExtensionContext) throws {
        guard let host = payload["host"] as? String, !host.isEmpty,
              let token = payload["token"] as? String, !token.isEmpty else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "missing host or token"])
            return
        }
        try keychain.save(token: token, host: host)
        respond(context: context, with: ["ok": true])
    }

    // MARK: - renderAndUpload (chunked)

    /// One-shot render+upload variant: takes the entire serialized HTML in
    /// `data`, renders to PDF and uploads to Paperless **all from inside the
    /// extension**. No App Group cross-app reads, no URL scheme launch, no
    /// containing-app handoff — this avoids the macOS 15+ "App Containers"
    /// prompt entirely.
    private func handleRenderOneShot(payload: [String: Any], context: NSExtensionContext) throws {
        guard let jobId = payload["requestId"] as? String,
              let serverURLStr = payload["serverURL"] as? String,
              let title = payload["title"] as? String,
              let sourceURL = payload["sourceURL"] as? String,
              let capturedAtStr = payload["capturedAt"] as? String,
              let html = payload["data"] as? String,
              let serverURL = URL(string: serverURLStr) else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "oneShot: missing fields"])
            return
        }
        let capturedAt = ISO8601DateFormatter().date(from: capturedAtStr) ?? Date()

        // Persist a queued JobRecord for the popup's recent-saves view.
        let record = JobRecord(
            jobId: jobId,
            state: .queued,
            sourceURL: sourceURL,
            title: title,
            capturedAt: capturedAt,
            queuedAt: Date()
        )
        try? jobStore.save(record)

        // Async fan-out: start the render+upload Task and let `respond()`
        // be called from the Task itself when it finishes. We do NOT block
        // the main thread — that would deadlock with the @MainActor Task.
        // NSExtensionContext stays valid until completeRequest is called.
        Task { @MainActor in
            var outbound: [String: Any]
            do {
                let renderer = PDFRenderer()
                let pdf = try await renderer.renderHTML(html)
                let client = PaperlessClient()
                let result = try await client.upload(
                    pdfData: pdf,
                    serverURL: serverURL,
                    title: title,
                    sourceURL: sourceURL,
                    capturedAt: capturedAt
                )
                self.markJobSucceeded(jobId: jobId, serverTaskId: result.serverTaskId)
                outbound = [
                    "ok": true,
                    "state": "succeeded",
                    "jobId": jobId,
                    "serverTaskId": result.serverTaskId,
                ]
            } catch let err as PaperlessClient.ClientError {
                let (kind, msg) = self.mapClientError(err)
                self.markJobFailed(jobId: jobId, kind: kind, message: msg)
                outbound = [
                    "ok": true,
                    "state": "failed",
                    "jobId": jobId,
                    "errorKind": kind.rawValue,
                    "message": msg,
                ]
            } catch {
                self.markJobFailed(jobId: jobId, kind: .unknown, message: error.localizedDescription)
                outbound = [
                    "ok": true,
                    "state": "failed",
                    "jobId": jobId,
                    "errorKind": "unknown",
                    "message": error.localizedDescription,
                ]
            }
            self.respond(context: context, with: outbound)
            self.log.debug("oneShot job=\(jobId, privacy: .public) done")
        }
    }

    private func markJobSucceeded(jobId: String, serverTaskId: String) {
        guard var r = try? jobStore.load(jobId: jobId) else { return }
        r.state = .succeeded
        r.completedAt = Date()
        r.serverTaskId = serverTaskId
        try? jobStore.save(r)
    }

    private func markJobFailed(jobId: String, kind: ErrorKind, message: String) {
        guard var r = try? jobStore.load(jobId: jobId) else { return }
        r.state = .failed
        r.failedAt = Date()
        r.errorKind = kind
        r.message = message
        try? jobStore.save(r)
    }

    private func mapClientError(_ err: PaperlessClient.ClientError) -> (ErrorKind, String) {
        switch err {
        case .missingToken: return (.notConfigured, "API token not stored.")
        case .httpsRequired: return (.httpsRequired, "Paperless server URL must use HTTPS.")
        case .authRejected(let m): return (.authRejected, m.isEmpty ? "Paperless rejected the API token." : m)
        case .tooLarge(let m): return (.tooLarge, m.isEmpty ? "PDF is too large." : m)
        case .rejectedByServer(let s, let b): return (.serverRejectedUpload, "HTTP \(s): \(b.prefix(200))")
        case .network(let n): return (.cannotReachServer, n.localizedDescription)
        case .unknown(let m): return (.unknown, m)
        }
    }

    private func handleRenderInit(payload: [String: Any], context: NSExtensionContext) throws {
        guard let jobId = payload["requestId"] as? String,
              let serverURL = payload["serverURL"] as? String,
              let title = payload["title"] as? String,
              let sourceURL = payload["sourceURL"] as? String,
              let capturedAtStr = payload["capturedAt"] as? String,
              let totalChunks = payload["totalChunks"] as? Int,
              let totalBytes = payload["totalBytes"] as? Int else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "init: missing fields"])
            return
        }

        // Initialize an empty buffer in UserDefaults (the chunks accumulate
        // here, then we move it to the final jobHtml.<jobId> key on commit).
        // Using UserDefaults instead of a shared file avoids the macOS 15+
        // "App Containers" privacy prompt.
        guard let defaults = AppGroup.defaults else {
            throw AppGroupError.containerUnavailable
        }
        defaults.set("", forKey: "jobHtmlPartial.\(jobId)")

        // Persist a transient job record marked queued at init time so the
        // popup can show "in flight" if the JS side dies before commit.
        let capturedAt = ISO8601DateFormatter().date(from: capturedAtStr) ?? Date()
        let record = JobRecord(
            jobId: jobId,
            state: .queued,
            sourceURL: sourceURL,
            title: title,
            capturedAt: capturedAt,
            queuedAt: Date()
        )
        try jobStore.save(record)

        // Stash init params keyed by jobId so commit knows them later.
        // UserDefaults rejects NSNull, so omit sourceUrlFieldId when null
        // and use Int.min as sentinel. JSON nulls arrive as NSNull, not nil.
        var initDict: [String: Any] = [
            "serverURL": serverURL,
            "totalChunks": totalChunks,
            "totalBytes": totalBytes,
            "writtenChunks": 0,
        ]
        if let fieldId = payload["sourceUrlFieldId"] as? Int {
            initDict["sourceUrlFieldId"] = fieldId
        }
        AppGroup.defaults?.set(initDict, forKey: "jobInit.\(jobId)")

        respond(context: context, with: ["ok": true])
        log.debug("init job \(jobId, privacy: .public) totalBytes=\(totalBytes) totalChunks=\(totalChunks)")
    }

    private func handleRenderChunk(payload: [String: Any], context: NSExtensionContext) throws {
        guard let jobId = payload["requestId"] as? String,
              let chunkIndex = payload["chunkIndex"] as? Int,
              let data = payload["data"] as? String else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "chunk: missing fields"])
            return
        }
        guard let defaults = AppGroup.defaults else {
            throw AppGroupError.containerUnavailable
        }
        let key = "jobHtmlPartial.\(jobId)"
        let existing = defaults.string(forKey: key) ?? ""
        defaults.set(existing + data, forKey: key)

        if var dict = defaults.dictionary(forKey: "jobInit.\(jobId)") {
            dict["writtenChunks"] = (dict["writtenChunks"] as? Int ?? 0) + 1
            defaults.set(dict, forKey: "jobInit.\(jobId)")
        }

        respond(context: context, with: ["ok": true])
        log.debug("chunk job=\(jobId, privacy: .public) idx=\(chunkIndex) bytes=\(data.utf8.count)")
    }

    private func handleRenderCommit(payload: [String: Any], context: NSExtensionContext) throws {
        guard let jobId = payload["requestId"] as? String else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "commit: missing requestId"])
            return
        }
        guard let init_ = AppGroup.defaults?.dictionary(forKey: "jobInit.\(jobId)") else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "no init for \(jobId)"])
            return
        }
        let totalChunks = init_["totalChunks"] as? Int ?? 0
        let written = init_["writtenChunks"] as? Int ?? 0
        if written != totalChunks {
            respond(context: context, with: [
                "ok": false, "errorKind": "unknown",
                "message": "expected \(totalChunks) chunks, got \(written)",
            ])
            return
        }

        // Move partial buffer to the final key the containing app reads.
        guard let defaults = AppGroup.defaults else {
            throw AppGroupError.containerUnavailable
        }
        let partialKey = "jobHtmlPartial.\(jobId)"
        let assembled = defaults.string(forKey: partialKey) ?? ""
        defaults.set(assembled, forKey: "jobHtml.\(jobId)")
        defaults.removeObject(forKey: partialKey)

        // Wake the containing app via the custom URL scheme.
        let url = URL(string: "paperless-clipper://render?jobId=\(jobId)")!
        openContainingApp(url: url)

        respond(context: context, with: ["ok": true, "state": "queued"])
        log.debug("commit job=\(jobId, privacy: .public); requested containing-app launch")
    }

    private func openContainingApp(url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        // Extensions can't directly open URLs; we fall through to the
        // documented `extensionContext` path. For the prototype, just log.
        // Phase 4 will wire NSExtensionContext.open(_:completionHandler:).
        log.debug("would open URL on iOS: \(url.absoluteString, privacy: .public)")
        #endif
    }

    // MARK: - getJobStatus / revealLastFailure

    private func handleGetJobStatus(payload: [String: Any], context: NSExtensionContext) throws {
        let pending = (try? jobStore.allPending()) ?? []
        let lastFailure = (try? jobStore.lastFailure())
        let recent = (try? jobStore.recentSuccesses()) ?? []
        let encoder = JSONEncoder.iso8601
        let out: [String: Any] = [
            "inFlight": (try? encoder.encode(pending.map(JobStatusJSON.init))).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [],
            "lastFailure": lastFailure.flatMap { try? encoder.encode(JobStatusJSON(record: $0)) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as Any,
            "recentSuccesses": (try? encoder.encode(recent.map(JobStatusJSON.init))).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [],
        ]
        respond(context: context, with: out)
    }

    private func handleRevealLastFailure(payload: [String: Any], context: NSExtensionContext) throws {
        respond(context: context, with: ["ok": true])
    }

    /// Block (with timeout) until the given job's record reaches a terminal
    /// state. Used by the chunked-upload path so the JS layer makes one
    /// `sendNativeMessage` call instead of polling. Mirrors the wait portion
    /// of `handleRenderOneShot`.
    private func handleWaitForJob(payload: [String: Any], context: NSExtensionContext) throws {
        guard let jobId = payload["requestId"] as? String else {
            respond(context: context, with: ["ok": false, "errorKind": "unknown", "message": "waitForJob: missing requestId"])
            return
        }
        let timeoutSec = 90.0
        let pollIntervalSec = 0.5
        let deadline = Date().addingTimeInterval(timeoutSec)
        var terminal: JobRecord?
        while Date() < deadline {
            if let r = try? jobStore.load(jobId: jobId),
               r.state == .succeeded || r.state == .failed {
                terminal = r
                break
            }
            Thread.sleep(forTimeInterval: pollIntervalSec)
        }
        if let r = terminal {
            var out: [String: Any] = [
                "ok": true,
                "state": r.state.rawValue,
                "jobId": r.jobId,
            ]
            if let tid = r.serverTaskId { out["serverTaskId"] = tid }
            if let kind = r.errorKind { out["errorKind"] = kind.rawValue }
            if let msg = r.message { out["message"] = msg }
            respond(context: context, with: out)
        } else {
            respond(context: context, with: [
                "ok": false,
                "errorKind": "unknown",
                "message": "Save did not finish within \(Int(timeoutSec))s.",
                "jobId": jobId,
            ])
        }
    }

    // MARK: - Plumbing

    private func respond(context: NSExtensionContext, with payload: [String: Any]) {
        let outbound = NSExtensionItem()
        outbound.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [outbound], completionHandler: nil)
    }
}

/// Wire-format helper matching `JobStatusSchema` in `web/src/shared/messages.ts`.
private struct JobStatusJSON: Codable {
    let jobId: String
    let state: String
    let sourceURL: String
    let title: String
    let queuedAt: String?
    let completedAt: String?
    let failedAt: String?
    let serverTaskId: String?
    let errorKind: String?
    let message: String?

    init(record: JobRecord) {
        self.jobId = record.jobId
        self.state = record.state.rawValue
        self.sourceURL = record.sourceURL
        self.title = record.title
        let iso = ISO8601DateFormatter()
        self.queuedAt = record.queuedAt.map { iso.string(from: $0) }
        self.completedAt = record.completedAt.map { iso.string(from: $0) }
        self.failedAt = record.failedAt.map { iso.string(from: $0) }
        self.serverTaskId = record.serverTaskId
        self.errorKind = record.errorKind?.rawValue
        self.message = record.message
    }
}
