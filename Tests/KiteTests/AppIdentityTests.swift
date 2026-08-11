import Foundation
import Testing
@testable import Kite

@Suite("Kite identity migration")
struct AppIdentityTests {
    @Test("Legacy application support data moves into Kite")
    func migratesLegacyDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KiteIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "SuperDD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: legacy.appending(path: "settings.json"))

        let destination = try AppIdentity.migrateApplicationSupportDirectory(in: root)

        #expect(destination.lastPathComponent == "Kite")
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Existing Kite data is never overwritten by legacy data")
    func preservesExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KiteIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Kite", directoryHint: .isDirectory)
        let legacy = root.appending(path: "SuperDD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("kite".utf8).write(to: destination.appending(path: "settings.json"))
        try Data("legacy".utf8).write(to: legacy.appending(path: "settings.json"))

        let resolved = try AppIdentity.migrateApplicationSupportDirectory(in: root)
        let data = try Data(contentsOf: resolved.appending(path: "settings.json"))

        #expect(String(decoding: data, as: UTF8.self) == "kite")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Duplicate legacy files are cleaned up after migration")
    func removesDuplicateLegacyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KiteIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Kite", directoryHint: .isDirectory)
        let legacy = root.appending(path: "SuperDD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: destination.appending(path: "settings.json"))
        try Data("same".utf8).write(to: legacy.appending(path: "settings.json"))

        _ = try AppIdentity.migrateApplicationSupportDirectory(in: root)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
