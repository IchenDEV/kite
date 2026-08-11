import Foundation
import OSLog

actor TrackerService {
    private let logger = Logger(subsystem: "com.chenli.superdd", category: "trackers")

    func synchronize(sources: [String], client: Aria2RPCClient) async -> Int {
        var trackers = Set<String>()
        await withTaskGroup(of: [String].self) { group in
            for source in sources {
                group.addTask { await Self.fetch(source) }
            }
            for await values in group { trackers.formUnion(values) }
        }

        guard !trackers.isEmpty else { return 0 }
        do {
            try await client.changeGlobalOption(["bt-tracker": .string(trackers.sorted().joined(separator: ","))])
            return trackers.count
        } catch {
            logger.warning("Could not apply tracker list: \(error.localizedDescription)")
            return 0
        }
    }

    private static func fetch(_ source: String) async -> [String] {
        guard let url = URL(string: source) else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("udp://") || $0.hasPrefix("ws://") || $0.hasPrefix("wss://") }
        } catch {
            return []
        }
    }
}
