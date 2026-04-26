import Foundation
import os.log

/// HTTP client for Paperless-ngx (T044, macOS).
///
/// v1 scope:
///   * POST /api/documents/post_document/ — multipart upload
///   * The source URL is preserved by appending it to the title
///     (R5 strategy 1). custom_fields wire-format validation (R5
///     strategy 2) is deferred until the user authorizes the curl
///     validator (T021/T022).
///
/// macOS uses a foreground URLSession for the prototype — the containing
/// app stays alive long enough for any reasonable upload to complete. The
/// iOS twin will use URLSessionConfiguration.background per research R3
/// because iOS suspends the extension before the upload finishes.
public final class PaperlessClient {

    public enum ClientError: Error {
        case missingToken
        case httpsRequired
        case authRejected(message: String)
        case rejectedByServer(status: Int, body: String)
        case tooLarge(message: String)
        case network(Error)
        case unknown(message: String)
    }

    public struct UploadResult {
        public let serverTaskId: String
    }

    private let log = Logger(subsystem: "org.czei.PaperlessClipper", category: "paperless-client")
    private let keychain = KeychainStore()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Upload a rendered PDF to Paperless. Returns the consume task id on success.
    public func upload(
        pdfData: Data,
        serverURL: URL,
        title: String,
        sourceURL: String,
        capturedAt: Date
    ) async throws -> UploadResult {
        guard PaperlessClientConfig.isAcceptableServerScheme(serverURL) else {
            throw ClientError.httpsRequired
        }
        guard let host = serverURL.host else {
            throw ClientError.unknown(message: "server URL has no host")
        }
        let token: String
        do {
            token = try keychain.read(host: host)
        } catch KeychainError.itemNotFound {
            throw ClientError.missingToken
        }

        let endpoint = serverURL.appendingPathComponent("api").appendingPathComponent("documents").appendingPathComponent("post_document/", isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        // Title carries the source URL appended (R5 strategy 1) so the link
        // survives even if Paperless has no source_url custom field.
        let archivalTitle = "\(title) — \(sourceURL)"

        let boundary = "paperless-clipper-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let body = makeMultipartBody(
            boundary: boundary,
            pdf: pdfData,
            title: archivalTitle,
            createdISO: ISO8601DateFormatter().string(from: capturedAt),
            sanitizedFilename: sanitizeFilename(title)
        )

        log.debug("uploading \(pdfData.count) bytes to \(endpoint.absoluteString, privacy: .public)")

        do {
            let (data, response) = try await session.upload(for: request, from: body)
            return try mapResponse(data: data, response: response)
        } catch let urlErr as URLError {
            throw ClientError.network(urlErr)
        }
    }

    private func mapResponse(data: Data, response: URLResponse) throws -> UploadResult {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.unknown(message: "non-HTTP response")
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            // Paperless returns the task id as a JSON string body, e.g. "\"abc-123\""
            let trimmed = bodyText.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
            return UploadResult(serverTaskId: trimmed.isEmpty ? "(unknown)" : trimmed)
        case 401, 403:
            throw ClientError.authRejected(message: bodyText)
        case 413:
            throw ClientError.tooLarge(message: bodyText)
        default:
            throw ClientError.rejectedByServer(status: http.statusCode, body: bodyText)
        }
    }

    private func makeMultipartBody(
        boundary: String,
        pdf: Data,
        title: String,
        createdISO: String,
        sanitizedFilename: String
    ) -> Data {
        var body = Data()
        let boundaryStart = "--\(boundary)\r\n".data(using: .utf8)!
        let boundaryEnd = "--\(boundary)--\r\n".data(using: .utf8)!

        // title
        body.append(boundaryStart)
        body.append("Content-Disposition: form-data; name=\"title\"\r\n\r\n".data(using: .utf8)!)
        body.append(title.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // created
        body.append(boundaryStart)
        body.append("Content-Disposition: form-data; name=\"created\"\r\n\r\n".data(using: .utf8)!)
        body.append(createdISO.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // document (PDF file)
        body.append(boundaryStart)
        body.append(
            "Content-Disposition: form-data; name=\"document\"; filename=\"\(sanitizedFilename).pdf\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(pdf)
        body.append("\r\n".data(using: .utf8)!)

        body.append(boundaryEnd)
        return body
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "paperless-clipper-save" }
        return String(trimmed.prefix(120))
    }
}
