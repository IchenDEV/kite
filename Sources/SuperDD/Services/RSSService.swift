import Foundation

struct RSSItem: Hashable, Sendable {
    let title: String
    let url: String
    let publishedAt: Date?
}

enum RSSServiceError: LocalizedError, Sendable {
    case invalidFeed
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "The RSS or Atom feed is invalid."
        case let .invalidResponse(status): "The feed server returned HTTP \(status)."
        }
    }
}

actor RSSService {
    func fetch(_ feed: AppSettings.RSSFeed) async throws -> [RSSItem] {
        guard let url = URL(string: feed.url) else { throw RSSServiceError.invalidFeed }
        var request = URLRequest(url: url)
        request.setValue("SuperDD/1.0 RSS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw RSSServiceError.invalidResponse(http.statusCode)
        }
        let parser = XMLParser(data: data)
        let delegate = RSSParser()
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? RSSServiceError.invalidFeed }
        return delegate.items
    }
}

private final class RSSParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    var items: [RSSItem] = []
    private var inEntry = false
    private var element = ""
    private var title = ""
    private var link = ""
    private var date = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName.lowercased()
        if element == "item" || element == "entry" {
            inEntry = true
            title = ""
            link = ""
            date = ""
        } else if inEntry, element == "enclosure", let url = attributeDict["url"] {
            link = url
        } else if inEntry, element == "link", let href = attributeDict["href"],
                  attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        switch element {
        case "title": title += string
        case "link", "guid": if link.isEmpty { link += string }
        case "pubdate", "published", "updated": date += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            let normalizedURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedURL.isEmpty {
                items.append(RSSItem(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: normalizedURL,
                    publishedAt: parseDate(date.trimmingCharacters(in: .whitespacesAndNewlines))
                ))
            }
            inEntry = false
        }
        element = ""
    }

    private func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

actor AutomationStateStore {
    private struct State: Codable {
        var watchedFiles = Set<String>()
        var rssURLs = Set<String>()
    }

    private let fileURL: URL
    private var state: State

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appending(path: "SuperDD/automation-state.json")
        }
        if let data = try? Data(contentsOf: self.fileURL), let state = try? JSONDecoder().decode(State.self, from: data) {
            self.state = state
        } else {
            state = State()
        }
    }

    func claimWatchedFile(_ url: URL) throws -> Bool {
        let key = url.standardizedFileURL.path
        guard state.watchedFiles.insert(key).inserted else { return false }
        try persist()
        return true
    }

    func claimRSSURL(_ url: String) throws -> Bool {
        guard state.rssURLs.insert(url).inserted else { return false }
        try persist()
        return true
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
    }
}
