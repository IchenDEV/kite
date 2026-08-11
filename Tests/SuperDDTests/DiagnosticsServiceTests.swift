import Foundation
import Testing
@testable import SuperDD

@Suite("Diagnostics export")
struct DiagnosticsServiceTests {
    @Test("ZIP is valid-shaped and redacts credentials")
    func export() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SuperDDDiagnosticsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "diagnostics.zip")
        var settings = AppSettings()
        settings.extensionSecret = "should-never-appear"
        settings.proxyPassword = "private-proxy-password"

        try await DiagnosticsService().export(to: destination, settings: settings, historyIntegrity: "ok")
        let data = try Data(contentsOf: destination)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(data.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        let raw = String(decoding: data, as: UTF8.self)
        #expect(!raw.contains("should-never-appear"))
        #expect(!raw.contains("private-proxy-password"))
        #expect(raw.contains("<redacted>"))
    }
}
