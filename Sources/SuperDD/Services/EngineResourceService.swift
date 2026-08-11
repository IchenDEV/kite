import Foundation
import OSLog

struct EngineResources: Sendable {
    let ed2kServerList: URL?
    let ed2kNodeList: URL?
    let peerBlocklist: URL?
}

enum EngineResourceService {
    private static let logger = Logger(subsystem: "com.chenli.superdd", category: "engine-resources")

    static func prepare(in supportDirectory: URL, settings: AppSettings) async -> EngineResources {
        let resourcesDirectory = supportDirectory.appending(path: "EngineResources", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        async let serverList = downloadIfNeeded(
            source: settings.ed2kServerListURL,
            destination: resourcesDirectory.appending(path: "server.met")
        )
        async let nodeList = downloadIfNeeded(
            source: settings.ed2kNodeListURL,
            destination: resourcesDirectory.appending(path: "nodes.dat")
        )
        async let blocklist = settings.enablePeerBlocklist
            ? downloadIfNeeded(source: settings.peerBlocklistURL, destination: resourcesDirectory.appending(path: "bt-peer-blocklist.txt"))
            : nil

        return await EngineResources(
            ed2kServerList: serverList,
            ed2kNodeList: nodeList,
            peerBlocklist: blocklist
        )
    }

    private static func downloadIfNeeded(source: String, destination: URL) async -> URL? {
        guard let url = URL(string: source), !source.isEmpty else { return existing(destination) }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let modificationDate = attributes[.modificationDate] as? Date,
           Date.now.timeIntervalSince(modificationDate) < 7 * 24 * 60 * 60,
           existing(destination) != nil {
            return destination
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode),
                  !data.isEmpty else { return existing(destination) }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            logger.warning("Could not refresh \(destination.lastPathComponent): \(error.localizedDescription)")
            return existing(destination)
        }
    }

    private static func existing(_ url: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else { return nil }
        return url
    }
}
