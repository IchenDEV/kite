import Foundation

enum TaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case normal
    case low

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TaskTransport: String, Codable, Sendable {
    case aria2
    case media
}

struct TaskMetadata: Codable, Equatable, Identifiable, Sendable {
    var id: String { gid }
    var gid: String
    var sourceURLs: [String]
    var sourceFilePath: String?
    var options: [String: JSONValue]
    var credentialProfileID: UUID?
    var label: String
    var priority: TaskPriority
    var scheduled: Bool
    var retryCount: Int
    var nextRetryAt: Date?
    var createdAt: Date
    var postProcessedAt: Date? = nil
    var transport: TaskTransport? = .aria2
    var localStatus: DownloadStatus? = nil
    var localCompletedLength: Int64? = nil
    var localTotalLength: Int64? = nil
    var localOutputPath: String? = nil
}
