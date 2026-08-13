import Foundation
import Testing
@testable import Kite

@Suite("Container preview service")
struct ContainerPreviewServiceTests {
    @Test("Single-file torrents prefer UTF-8 names and deduplicate trackers")
    func singleFileTorrent() throws {
        let tracker = "https://tracker.example/announce"
        let data = TestBencode.dictionary([
            "announce": .string(tracker),
            "announce-list": .list([
                .list([.string(tracker)]),
                .list([.string("udp://tracker.example:6969/announce")]),
            ]),
            "info": .dictionary([
                "length": .integer(4_096),
                "name": .string("fallback.iso"),
                "name.utf-8": .string("Kite 镜像.iso"),
            ]),
        ]).encoded()

        let preview = ContainerPreviewService().preview(data: data, kind: .torrent)

        #expect(preview.error == nil)
        #expect(preview.kind == .torrent)
        #expect(preview.displayName == "Kite 镜像.iso")
        #expect(preview.fileCount == 1)
        #expect(preview.totalLength == 4_096)
        #expect(preview.files == [
            ContainerPreviewFile(relativePath: "Kite 镜像.iso", length: 4_096),
        ])
        #expect(preview.trackerCount == 2)
    }

    @Test("Multi-file torrents expose relative paths and a checked total")
    func multiFileTorrent() {
        let data = TestBencode.dictionary([
            "info": .dictionary([
                "files": .list([
                    .dictionary([
                        "length": .integer(3),
                        "path": .list([.string("docs"), .string("readme.txt")]),
                    ]),
                    .dictionary([
                        "length": .integer(5),
                        "path.utf-8": .list([.string("资源"), .string("指南.pdf")]),
                    ]),
                ]),
                "name": .string("Kite Bundle"),
            ]),
        ]).encoded()

        let preview = ContainerPreviewService().preview(data: data, kind: .torrent)

        #expect(preview.error == nil)
        #expect(preview.displayName == "Kite Bundle")
        #expect(preview.fileCount == 2)
        #expect(preview.totalLength == 8)
        #expect(preview.files.map(\.relativePath) == ["docs/readme.txt", "资源/指南.pdf"])
        #expect(preview.trackerCount == 0)
    }

    @Test("Metalink v4 namespaces expose files and preserve unknown sizes")
    func metalinkV4() {
        let data = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="releases/Kite.dmg"><size>8192</size></file>
          <file name="checksums.txt" />
        </metalink>
        """#.utf8)

        let preview = ContainerPreviewService().preview(
            data: data,
            kind: .metalink,
            displayName: "Kite Release.meta4"
        )

        #expect(preview.error == nil)
        #expect(preview.kind == .metalink)
        #expect(preview.displayName == "Kite Release.meta4")
        #expect(preview.fileCount == 2)
        #expect(preview.totalLength == nil)
        #expect(preview.files == [
            ContainerPreviewFile(relativePath: "releases/Kite.dmg", length: 8_192),
            ContainerPreviewFile(relativePath: "checksums.txt", length: nil),
        ])
        #expect(preview.trackerCount == nil)
    }

    @Test("Metalink v3 files can be previewed from a local URL")
    func metalinkV3URL() throws {
        let data = Data(#"""
        <metalink xmlns="http://www.metalinker.org/">
          <files>
            <file name="Kite.zip"><size>1024</size></file>
          </files>
        </metalink>
        """#.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kite-container-preview-\(UUID().uuidString)")
            .appendingPathExtension("metalink")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = ContainerPreviewService().preview(fileAt: url)

        #expect(preview.error == nil)
        #expect(preview.displayName == "Kite.zip")
        #expect(preview.fileCount == 1)
        #expect(preview.totalLength == 1_024)
    }

    @Test("Malformed, deeply nested, and oversized torrent data is rejected")
    func unsafeTorrentStructures() {
        let service = ContainerPreviewService()

        let malformed = service.preview(
            data: Data("d4:infod4:name4:Test".utf8),
            kind: .torrent
        )
        #expect(malformed.error?.contains("malformed") == true)

        let nesting = String(repeating: "l", count: 50) + String(repeating: "e", count: 50)
        let deeplyNested = service.preview(data: Data(nesting.utf8), kind: .torrent)
        #expect(deeplyNested.error?.contains("nesting is too deep") == true)

        let oversized = service.preview(
            data: Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1),
            kind: .torrent
        )
        #expect(oversized.error?.contains("too large") == true)
    }

    @Test("Container paths cannot escape the destination")
    func unsafePaths() {
        let torrent = TestBencode.dictionary([
            "info": .dictionary([
                "files": .list([
                    .dictionary([
                        "length": .integer(1),
                        "path": .list([.string(".."), .string("secret")]),
                    ]),
                ]),
                "name": .string("Bundle"),
            ]),
        ]).encoded()
        let torrentPreview = ContainerPreviewService().preview(data: torrent, kind: .torrent)
        #expect(torrentPreview.error?.contains("unsafe path") == true)

        let metalink = Data(#"""
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="../secret"><size>1</size></file>
        </metalink>
        """#.utf8)
        let metalinkPreview = ContainerPreviewService().preview(data: metalink, kind: .metalink)
        #expect(metalinkPreview.error?.contains("unsafe path") == true)
    }
}

private indirect enum TestBencode {
    case integer(Int64)
    case string(String)
    case list([TestBencode])
    case dictionary([String: TestBencode])

    func encoded() -> Data {
        switch self {
        case let .integer(value):
            Data("i\(value)e".utf8)
        case let .string(value):
            Self.bytes(Data(value.utf8))
        case let .list(values):
            Data("l".utf8)
                + values.reduce(into: Data()) { $0.append($1.encoded()) }
                + Data("e".utf8)
        case let .dictionary(values):
            Data("d".utf8)
                + values.keys.sorted().reduce(into: Data()) { result, key in
                    result.append(Self.bytes(Data(key.utf8)))
                    result.append(values[key]!.encoded())
                }
                + Data("e".utf8)
        }
    }

    private static func bytes(_ data: Data) -> Data {
        Data("\(data.count):".utf8) + data
    }
}
