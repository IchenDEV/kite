import Foundation

actor TaskMetadataStore {
    private let fileURL: URL
    private let sourcesDirectory: URL
    private var values: [String: TaskMetadata]

    init(fileURL: URL? = nil) {
        let base: URL
        if let fileURL {
            self.fileURL = fileURL
            base = fileURL.deletingLastPathComponent()
        } else {
            let applicationSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            base = applicationSupport.appending(path: "SuperDD", directoryHint: .isDirectory)
            self.fileURL = base.appending(path: "task-metadata.json")
        }
        sourcesDirectory = base.appending(path: "TaskSources", directoryHint: .isDirectory)
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: TaskMetadata].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    func metadata(for gid: String) -> TaskMetadata? { values[gid] }

    func all() -> [TaskMetadata] { Array(values.values) }

    func upsert(_ value: TaskMetadata) throws {
        values[value.gid] = value
        try persist()
    }

    func remove(gid: String) throws {
        if let path = values[gid]?.sourceFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        values.removeValue(forKey: gid)
        try persist()
    }

    func replaceGID(_ oldGID: String, with newGID: String, retryCount: Int) throws {
        guard var value = values.removeValue(forKey: oldGID) else { return }
        value.gid = newGID
        value.retryCount = retryCount
        value.nextRetryAt = nil
        if let oldPath = value.sourceFilePath {
            let oldURL = URL(fileURLWithPath: oldPath)
            let newURL = sourcesDirectory.appending(path: "\(newGID).\(oldURL.pathExtension)")
            try? FileManager.default.moveItem(at: oldURL, to: newURL)
            value.sourceFilePath = newURL.path
        }
        values[newGID] = value
        try persist()
    }

    func updateRetry(gid: String, count: Int, nextRetryAt: Date?) throws {
        guard var value = values[gid] else { return }
        value.retryCount = count
        value.nextRetryAt = nextRetryAt
        values[gid] = value
        try persist()
    }

    func archiveTorrent(data: Data, gid: String) throws -> URL {
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        let url = sourcesDirectory.appending(path: "\(gid).torrent")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }
}
