import Foundation
import Testing
@testable import Kite

@Suite("JSON and aria2 model decoding")
struct JSONValueTests {
    @Test("JSON values preserve nested shapes")
    func nestedJSON() throws {
        let data = Data(#"{"name":"file.zip","bytes":"42","selected":true,"items":[1,null]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let object = try #require(value.objectValue)
        #expect(object.string("name") == "file.zip")
        #expect(object.int64("bytes") == 42)
        #expect(object.bool("selected") == true)
        #expect(object.array("items").count == 2)
    }

    @Test("aria2 task derives a display name and progress")
    func taskModel() {
        let task = DownloadTask(json: [
            "gid": .string("abc123"),
            "status": .string("active"),
            "totalLength": .string("100"),
            "completedLength": .string("25"),
            "downloadSpeed": .string("5"),
            "files": .array([
                .object([
                    "index": .string("1"),
                    "path": .string("/tmp/archive.zip"),
                    "length": .string("100"),
                    "completedLength": .string("25"),
                    "selected": .string("true"),
                    "uris": .array([]),
                ]),
            ]),
        ])
        #expect(task.gid == "abc123")
        #expect(task.name == "archive.zip")
        #expect(task.progress == 0.25)
        #expect(task.estimatedSecondsRemaining == 15)
    }
}
