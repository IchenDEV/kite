import Foundation
import Testing
@testable import Kite

@Suite("Power-user features")
struct PowerFeatureTests {
    @Test("Torrent creator writes bencoded SHA-1 pieces")
    func torrentCreator() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KiteTorrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "payload.txt")
        try Data("hello torrent".utf8).write(to: source)
        let destination = directory.appending(path: "payload.torrent")
        try await TorrentCreator().create(TorrentCreationRequest(
            sourceURL: source,
            destinationURL: destination,
            trackers: ["https://tracker.example/announce"],
            pieceLength: 16 * 1_024,
            isPrivate: true,
            comment: "test"
        ))
        let data = try Data(contentsOf: destination)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("d8:announce"))
        #expect(text.contains("4:info"))
        #expect(text.contains("6:pieces20:"))
        #expect(text.contains("7:privatei1e"))
    }

    @Test("GeoIP CSV supports CIDR and explicit ranges")
    func geoIP() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "KiteGeoIP-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("10.0.0.0/8,Private\n192.168.1.0,192.168.1.255,LAN\n".utf8).write(to: url)
        let service = GeoIPService()
        try await service.configure(source: url.path)
        #expect(await service.country(for: "10.2.3.4") == "Private")
        #expect(await service.country(for: "192.168.1.42") == "LAN")
        #expect(await service.country(for: "8.8.8.8") == nil)
    }

    @Test("Resolver plugin executes in the isolated helper")
    func resolverPlugin() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KitePlugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appending(path: "example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"id":"example","name":"Example","version":"1.0.0","entry":"index.js"}"#.utf8)
            .write(to: plugin.appending(path: "manifest.json"))
        try Data("function resolve(input) { return input.url + '?resolved=1'; }".utf8)
            .write(to: plugin.appending(path: "index.js"))
        let service = PluginService(directory: directory)
        let resolved = await service.resolve("https://example.com/file", enabled: true)
        #expect(resolved == ["https://example.com/file?resolved=1"])
    }
}
