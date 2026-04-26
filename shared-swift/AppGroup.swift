import Foundation

/// Identifiers and paths for the App Group shared by the macOS app, the iOS
/// app, and the Safari Web Extension. The same identifier string is used on
/// both platforms — Xcode prepends the team identifier on macOS at sign time,
/// transparently. Do not branch on `#if os(macOS)`.
public enum AppGroup {
    public static let identifier = "group.org.czei.PaperlessClipper"

    /// The shared `UserDefaults` suite used for job-state records (see
    /// `contracts/storage-schema.md`). Returns `nil` if the App Group is not
    /// configured on the current target — call sites should treat that as a
    /// fatal misconfiguration during development and a `notConfigured` state
    /// at runtime.
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Container URL for the App Group. Returns `nil` if the capability is
    /// missing — same treatment as `defaults`.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Directory holding per-job HTML cache files. Created lazily on first
    /// write. Files are deleted when their job reaches a terminal state.
    public static var jobsCacheDirectory: URL? {
        guard let container = containerURL else { return nil }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    /// Path for one job's serialized HTML.
    public static func jobCacheFile(jobId: String) -> URL? {
        jobsCacheDirectory?.appendingPathComponent("\(jobId).html")
    }

    /// Make sure the jobs cache directory exists. Safe to call repeatedly.
    public static func ensureJobsCacheDirectory() throws {
        guard let dir = jobsCacheDirectory else {
            throw AppGroupError.containerUnavailable
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

public enum AppGroupError: Error {
    case containerUnavailable
}
