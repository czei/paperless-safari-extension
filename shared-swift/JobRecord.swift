import Foundation

/// One in-flight or terminated save job.
///
/// Persisted in App Group `UserDefaults` under keys
/// `pendingJobs.<jobId>` (JSON-encoded JobRecord) and surfaced to the
/// extension JS layer via `getJobStatus`. See `contracts/storage-schema.md`.
public struct JobRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued
        case rendering
        case uploading
        case succeeded
        case failed
    }

    public var jobId: String
    public var state: State
    public var sourceURL: String
    public var title: String
    public var capturedAt: Date
    public var queuedAt: Date?
    public var completedAt: Date?
    public var failedAt: Date?
    public var errorKind: ErrorKind?
    public var message: String?
    public var serverTaskId: String?

    public init(
        jobId: String,
        state: State,
        sourceURL: String,
        title: String,
        capturedAt: Date,
        queuedAt: Date? = nil,
        completedAt: Date? = nil,
        failedAt: Date? = nil,
        errorKind: ErrorKind? = nil,
        message: String? = nil,
        serverTaskId: String? = nil
    ) {
        self.jobId = jobId
        self.state = state
        self.sourceURL = sourceURL
        self.title = title
        self.capturedAt = capturedAt
        self.queuedAt = queuedAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.errorKind = errorKind
        self.message = message
        self.serverTaskId = serverTaskId
    }
}

/// Storage keys for App Group `UserDefaults`.
public enum JobStorageKeys {
    public static func pendingJob(_ jobId: String) -> String { "pendingJobs.\(jobId)" }
    public static let pendingJobsIndex = "pendingJobsIndex"  // [String] of jobIds
    public static let lastFailureJobId = "lastFailureJobId"
    public static let recentSuccesses = "recentSuccesses"    // [JobRecord], bounded
    public static let recentSuccessesLimit = 10
}

/// Read/write helpers for the App Group `UserDefaults` job-state keyspace.
public struct JobStore {
    public init() {}

    public func save(_ record: JobRecord) throws {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        let data = try JSONEncoder.iso8601.encode(record)
        defaults.set(data, forKey: JobStorageKeys.pendingJob(record.jobId))

        var index = defaults.stringArray(forKey: JobStorageKeys.pendingJobsIndex) ?? []
        if !index.contains(record.jobId) {
            index.append(record.jobId)
            defaults.set(index, forKey: JobStorageKeys.pendingJobsIndex)
        }

        if record.state == .failed {
            defaults.set(record.jobId, forKey: JobStorageKeys.lastFailureJobId)
        } else if record.state == .succeeded {
            try appendRecentSuccess(record, defaults: defaults)
        }
    }

    public func load(jobId: String) throws -> JobRecord? {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        guard let data = defaults.data(forKey: JobStorageKeys.pendingJob(jobId)) else { return nil }
        return try JSONDecoder.iso8601.decode(JobRecord.self, from: data)
    }

    public func remove(jobId: String) throws {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        defaults.removeObject(forKey: JobStorageKeys.pendingJob(jobId))

        var index = defaults.stringArray(forKey: JobStorageKeys.pendingJobsIndex) ?? []
        index.removeAll { $0 == jobId }
        defaults.set(index, forKey: JobStorageKeys.pendingJobsIndex)

        if defaults.string(forKey: JobStorageKeys.lastFailureJobId) == jobId {
            defaults.removeObject(forKey: JobStorageKeys.lastFailureJobId)
        }
    }

    public func allPending() throws -> [JobRecord] {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        let index = defaults.stringArray(forKey: JobStorageKeys.pendingJobsIndex) ?? []
        return try index.compactMap { try load(jobId: $0) }
    }

    public func recentSuccesses() throws -> [JobRecord] {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        guard let data = defaults.data(forKey: JobStorageKeys.recentSuccesses) else { return [] }
        return try JSONDecoder.iso8601.decode([JobRecord].self, from: data)
    }

    public func lastFailure() throws -> JobRecord? {
        guard let defaults = AppGroup.defaults else { throw AppGroupError.containerUnavailable }
        guard let jobId = defaults.string(forKey: JobStorageKeys.lastFailureJobId) else { return nil }
        return try load(jobId: jobId)
    }

    private func appendRecentSuccess(_ record: JobRecord, defaults: UserDefaults) throws {
        var current = (try? recentSuccesses()) ?? []
        current.insert(record, at: 0)
        if current.count > JobStorageKeys.recentSuccessesLimit {
            current = Array(current.prefix(JobStorageKeys.recentSuccessesLimit))
        }
        let data = try JSONEncoder.iso8601.encode(current)
        defaults.set(data, forKey: JobStorageKeys.recentSuccesses)
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
