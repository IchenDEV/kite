import CryptoKit
import Foundation

struct PluginCatalogItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let downloadURL: URL
    let sha256: String
}

struct PluginDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let entry: String
    var permissions: [String] = []
    var directory: String = ""

    enum CodingKeys: String, CodingKey { case id, name, version, entry, permissions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        entry = try values.decodeIfPresent(String.self, forKey: .entry) ?? "index.js"
        permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        directory = ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(version, forKey: .version)
        try values.encode(entry, forKey: .entry)
        try values.encode(permissions, forKey: .permissions)
    }
}

actor PluginService {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? AppIdentity.applicationSupportDirectory()) ?? FileManager.default.temporaryDirectory
            self.directory = base.appending(path: "Plugins", directoryHint: .isDirectory)
        }
    }

    func discover() -> [PluginDescriptor] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  var descriptor = try? JSONDecoder().decode(PluginDescriptor.self, from: data),
                  !descriptor.id.isEmpty, !descriptor.name.isEmpty else { return nil }
            descriptor.directory = folder.path
            return descriptor
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func resolve(_ input: String, enabled: Bool) async -> [String] {
        guard enabled else { return [input] }
        var values = [input]
        for plugin in discover() {
            var next: [String] = []
            for value in values {
                let resolved = (try? await run(plugin: plugin, input: value)) ?? [value]
                next.append(contentsOf: resolved.isEmpty ? [value] : resolved)
            }
            values = Array(next.prefix(1_000))
        }
        return values
    }

    func pluginsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func fetchCatalog(from value: String) async throws -> [PluginCatalogItem] {
        guard let url = URL(string: value) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if let direct = try? JSONDecoder().decode([PluginCatalogItem].self, from: data) { return direct }
        struct Catalog: Decodable { let plugins: [PluginCatalogItem] }
        return try JSONDecoder().decode(Catalog.self, from: data).plugins
    }

    func install(_ item: PluginCatalogItem) async throws {
        guard item.sha256.count == 64 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Plugin registry entry has no valid SHA-256 digest"])
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: item.downloadURL)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let digest = try sha256(temporaryURL)
        guard digest.caseInsensitiveCompare(item.sha256) == .orderedSame else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Plugin SHA-256 verification failed"])
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: "KitePlugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let entries = try await processOutput("/usr/bin/zipinfo", ["-1", temporaryURL.path])
        for entry in entries.split(whereSeparator: \.isNewline) {
            let path = String(entry).replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Plugin archive contains an unsafe path"])
            }
        }
        _ = try await processOutput("/usr/bin/ditto", ["-x", "-k", temporaryURL.path, temporaryDirectory.path])
        let manifestCandidates = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let root = FileManager.default.fileExists(atPath: temporaryDirectory.appending(path: "manifest.json").path)
            ? temporaryDirectory
            : manifestCandidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
        guard let root,
              let data = try? Data(contentsOf: root.appending(path: "manifest.json")),
              let descriptor = try? JSONDecoder().decode(PluginDescriptor.self, from: data),
              descriptor.id == item.id else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Plugin manifest does not match the registry entry"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: item.id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: destination, resultingItemURL: &trashURL)
        }
        try FileManager.default.copyItem(at: root, to: destination)
    }

    private func run(plugin: PluginDescriptor, input: String) async throws -> [String] {
        let host = try resolveHost()
        let request = try JSONSerialization.data(withJSONObject: ["pluginPath": plugin.directory, "input": input])
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = host
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            try process.run()
            inputPipe.fileHandleForWriting.write(request)
            try inputPipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "Plugin \(plugin.name) timed out"])
            }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [input] }
            if let error = object["error"] as? String { throw NSError(domain: "KitePlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            return object["urls"] as? [String] ?? [input]
        }.value
    }

    private func resolveHost() throws -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: "Helpers/kite-plugin-host")) }
        if let executable = Bundle.main.executableURL { candidates.append(executable.deletingLastPathComponent().appending(path: "kite-plugin-host")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/debug/kite-plugin-host"))
        guard let host = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The Kite plugin host is missing"])
        }
        return host
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func processOutput(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
