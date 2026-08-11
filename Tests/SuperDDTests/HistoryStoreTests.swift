import Foundation
import Testing
@testable import SuperDD

@Suite("SQLite download history")
struct HistoryStoreTests {
    @Test("Terminal tasks are stored, listed, and removed")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SuperDDTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appending(path: "history.sqlite3"))
        let task = DownloadTask(json: [
            "gid": .string("done-1"),
            "status": .string("complete"),
            "totalLength": .string("100"),
            "completedLength": .string("100"),
            "dir": .string("/tmp"),
            "files": .array([
                .object([
                    "index": .string("1"),
                    "path": .string("/tmp/file.bin"),
                    "length": .string("100"),
                    "completedLength": .string("100"),
                    "selected": .string("true"),
                    "uris": .array([]),
                ]),
            ]),
        ])

        try await store.upsert(task: task, at: Date(timeIntervalSince1970: 100))
        let records = try await store.records()
        #expect(records.count == 1)
        #expect(records.first?.name == "file.bin")
        #expect(records.first?.completedAt == Date(timeIntervalSince1970: 100))

        try await store.remove(id: "done-1")
        #expect(try await store.records().isEmpty)
    }
}
