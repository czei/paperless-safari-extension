import Foundation

/// User-supplied connection details. Stored across two locations: `serverURL`
/// in `browser.storage.local`, `apiToken` in the App-Group-shared Keychain.
public struct ServerConfig: Equatable, Sendable {
    public var serverURL: URL
    public var sourceUrlFieldId: Int?
    public var lastVerifiedAt: Date?

    public init(serverURL: URL, sourceUrlFieldId: Int? = nil, lastVerifiedAt: Date? = nil) {
        self.serverURL = serverURL
        self.sourceUrlFieldId = sourceUrlFieldId
        self.lastVerifiedAt = lastVerifiedAt
    }

    /// Validate a user-entered string as a Paperless server URL.
    /// Enforces FR-014: HTTPS-only.
    public static func parse(_ raw: String) -> Result<URL, ServerConfigError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return .failure(.malformed)
        }

        guard PaperlessClientConfig.isAcceptableServerScheme(url) else {
            return .failure(.notHTTPS)
        }

        // Normalize: strip trailing slash, drop fragment/query.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        components?.path = path

        guard let normalized = components?.url else { return .failure(.malformed) }
        return .success(normalized)
    }
}

public enum ServerConfigError: Error, Equatable {
    case empty
    case malformed
    case notHTTPS
}

/// User-facing error categories. Matches `data-model.md`'s ErrorKind table
/// 1:1. Display labels are intentionally short; richer per-case context is
/// passed alongside as a separate message string.
public enum ErrorKind: String, Codable, Equatable, Sendable {
    case notConfigured
    case httpsRequired
    case cannotReachServer
    case authRejected
    case pageCannotBeCaptured
    case serverRejectedUpload
    case tooLarge
    case cancelled
    case unknown

    public var displayLabel: String {
        switch self {
        case .notConfigured:
            return "Set up your Paperless server in settings to start saving pages."
        case .httpsRequired:
            return "Paperless server URL must use HTTPS."
        case .cannotReachServer:
            return "Couldn't reach the Paperless server."
        case .authRejected:
            return "Paperless rejected the API token. Check settings."
        case .pageCannotBeCaptured:
            return "This page can't be saved."
        case .serverRejectedUpload:
            return "Paperless wouldn't accept the upload."
        case .tooLarge:
            return "This page is too large to save."
        case .cancelled:
            return "Save cancelled."
        case .unknown:
            return "Save failed."
        }
    }

    /// Convert an HTTP status code into the right ErrorKind for an upload
    /// outcome. Caller may further refine "unknown" with the response body.
    public static func from(httpStatus: Int) -> ErrorKind {
        switch httpStatus {
        case 200..<300: return .unknown // success path; not an error
        case 401, 403: return .authRejected
        case 413: return .tooLarge
        case 400..<500: return .serverRejectedUpload
        case 500..<600: return .serverRejectedUpload
        default: return .unknown
        }
    }
}
