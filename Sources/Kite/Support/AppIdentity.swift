import Foundation

enum AppIdentity {
    static let name = "Kite"
    static let bundleIdentifier = "com.chenli.kite"
    static let applicationSupportDirectoryName = "Kite"

    private static let legacyApplicationSupportDirectoryName = "SuperDD"

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try migrateApplicationSupportDirectory(in: base)
    }

    static func migrateApplicationSupportDirectory(
        in base: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = base.appending(path: applicationSupportDirectoryName, directoryHint: .isDirectory)
        let legacy = base.appending(path: legacyApplicationSupportDirectoryName, directoryHint: .isDirectory)

        if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.moveItem(at: legacy, to: destination)
            } catch {
                try fileManager.copyItem(at: legacy, to: destination)
            }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: legacy.path) {
            for source in try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                let target = destination.appending(path: source.lastPathComponent)
                if !fileManager.fileExists(atPath: target.path) {
                    try fileManager.moveItem(at: source, to: target)
                } else if fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
                    try fileManager.removeItem(at: source)
                }
            }
            if try fileManager.contentsOfDirectory(atPath: legacy.path).isEmpty {
                try fileManager.removeItem(at: legacy)
            }
        }
        return destination
    }
}
