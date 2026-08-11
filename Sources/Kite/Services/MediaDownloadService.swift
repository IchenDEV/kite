import Foundation

enum MediaDownloadError: LocalizedError, Sendable {
    case invalidManifest
    case unsupportedEncryption(String)
    case noSegments
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The media manifest could not be parsed."
        case let .unsupportedEncryption(method): "Encrypted HLS method \(method) is not supported."
        case .noSegments: "The media manifest contains no downloadable segments."
        case let .invalidResponse(status): "The media server returned HTTP \(status)."
        }
    }
}

struct MediaDownloadProgress: Sendable {
    let completedSegments: Int
    let totalSegments: Int
    let downloadedBytes: Int64
    let bytesPerSecond: Int64

    var fraction: Double {
        totalSegments > 0 ? Double(completedSegments) / Double(totalSegments) : 0
    }
}

struct MediaDownloadRequest: Sendable {
    let sourceURL: URL
    let destinationDirectory: URL
    let filename: String
    let preferredHeight: Int
    let headers: [String: String]
}

private struct MediaSegment: Codable, Sendable {
    let url: URL
    let byteRange: String?
}

private struct ResolvedMediaManifest: Sendable {
    let segments: [MediaSegment]
    let fileExtension: String
}

private struct MediaCheckpoint: Codable, Sendable {
    let sourceURL: URL
    var completedSegments: Int
    var downloadedBytes: Int64
}

actor MediaDownloadService {
    func download(
        _ request: MediaDownloadRequest,
        progress: @escaping @Sendable (MediaDownloadProgress) -> Void
    ) async throws -> URL {
        let manifest = try await resolveManifest(request)
        guard !manifest.segments.isEmpty else { throw MediaDownloadError.noSegments }

        try FileManager.default.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)
        let baseName = request.filename.isEmpty
            ? defaultFilename(for: request.sourceURL)
            : request.filename
        let finalURL = request.destinationDirectory
            .appending(path: baseName)
            .appendingPathExtensionIfMissing(manifest.fileExtension)
        let newPartialURL = finalURL.appendingPathExtension("kite-part")
        let legacyPartialURL = finalURL.appendingPathExtension("superdd-part")
        let partialURL = FileManager.default.fileExists(atPath: newPartialURL.path)
            ? newPartialURL
            : (FileManager.default.fileExists(atPath: legacyPartialURL.path) ? legacyPartialURL : newPartialURL)
        let newCheckpointURL = finalURL.appendingPathExtension("kite-resume.json")
        let legacyCheckpointURL = finalURL.appendingPathExtension("superdd-resume.json")
        let checkpointURL = FileManager.default.fileExists(atPath: newCheckpointURL.path)
            ? newCheckpointURL
            : (FileManager.default.fileExists(atPath: legacyCheckpointURL.path) ? legacyCheckpointURL : newCheckpointURL)

        var checkpoint = loadCheckpoint(checkpointURL, sourceURL: request.sourceURL)
        if checkpoint.completedSegments > manifest.segments.count
            || !FileManager.default.fileExists(atPath: partialURL.path) {
            checkpoint = MediaCheckpoint(sourceURL: request.sourceURL, completedSegments: 0, downloadedBytes: 0)
        }
        if checkpoint.completedSegments == 0 {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var intervalBytes: Int64 = 0
        var intervalStart = ContinuousClock.now
        for index in checkpoint.completedSegments ..< manifest.segments.count {
            try Task.checkCancellation()
            var segmentRequest = URLRequest(url: manifest.segments[index].url)
            request.headers.forEach { segmentRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
            if let range = manifest.segments[index].byteRange {
                segmentRequest.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
            }
            let (data, response) = try await URLSession.shared.data(for: segmentRequest)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw MediaDownloadError.invalidResponse(http.statusCode)
            }
            try handle.write(contentsOf: data)
            checkpoint.completedSegments = index + 1
            checkpoint.downloadedBytes += Int64(data.count)
            intervalBytes += Int64(data.count)
            try persist(checkpoint, to: checkpointURL)

            let elapsed = intervalStart.duration(to: .now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let speed = elapsedSeconds > 0 ? Int64(Double(intervalBytes) / elapsedSeconds) : 0
            progress(MediaDownloadProgress(
                completedSegments: checkpoint.completedSegments,
                totalSegments: manifest.segments.count,
                downloadedBytes: checkpoint.downloadedBytes,
                bytesPerSecond: speed
            ))
            if elapsedSeconds >= 1 {
                intervalBytes = 0
                intervalStart = .now
            }
        }

        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        try? FileManager.default.removeItem(at: checkpointURL)
        return finalURL
    }

    private func resolveManifest(_ request: MediaDownloadRequest) async throws -> ResolvedMediaManifest {
        let text = try await fetchText(request.sourceURL, headers: request.headers)
        if request.sourceURL.pathExtension.lowercased() == "m3u8" || text.hasPrefix("#EXTM3U") {
            return try await resolveHLS(text: text, manifestURL: request.sourceURL, request: request)
        }
        if request.sourceURL.pathExtension.lowercased() == "mpd" || text.contains("<MPD") {
            return try resolveDASH(text: text, manifestURL: request.sourceURL, preferredHeight: request.preferredHeight)
        }
        throw MediaDownloadError.invalidManifest
    }

    private func resolveHLS(
        text: String,
        manifestURL: URL,
        request: MediaDownloadRequest
    ) async throws -> ResolvedMediaManifest {
        let lines = text.components(separatedBy: .newlines)
        var variants: [(height: Int, bandwidth: Int, url: URL)] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let value = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: manifestURL)?.absoluteURL else { continue }
            let attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            let height = attributes["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0
            let bandwidth = Int(attributes["BANDWIDTH"] ?? "0") ?? 0
            variants.append((height, bandwidth, url))
        }
        if !variants.isEmpty {
            let eligible = variants.filter { $0.height == 0 || $0.height <= request.preferredHeight }
            let chosen = (eligible.isEmpty ? variants : eligible).max {
                ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth)
            }!
            let variantText = try await fetchText(chosen.url, headers: request.headers)
            return try await resolveHLS(text: variantText, manifestURL: chosen.url, request: request)
        }

        var segments: [MediaSegment] = []
        var pendingRange: String?
        var nextRangeOffset: Int64 = 0
        var initializationSegment: MediaSegment?
        for lineValue in lines {
            let line = lineValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attributes["METHOD"] ?? "NONE"
                if method != "NONE" { throw MediaDownloadError.unsupportedEncryption(method) }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attributes["URI"], let url = URL(string: uri, relativeTo: manifestURL)?.absoluteURL {
                    initializationSegment = MediaSegment(url: url, byteRange: rangeHeader(attributes["BYTERANGE"], offset: &nextRangeOffset))
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = rangeHeader(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), offset: &nextRangeOffset)
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: manifestURL)?.absoluteURL {
                segments.append(MediaSegment(url: url, byteRange: pendingRange))
                pendingRange = nil
            }
        }
        if let initializationSegment { segments.insert(initializationSegment, at: 0) }
        let fileExtension = segments.first?.url.pathExtension.lowercased() == "ts" ? "ts" : "mp4"
        return ResolvedMediaManifest(segments: segments, fileExtension: fileExtension)
    }

    private func resolveDASH(text: String, manifestURL: URL, preferredHeight: Int) throws -> ResolvedMediaManifest {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = DASHParser(manifestURL: manifestURL)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? MediaDownloadError.invalidManifest }
        let candidates = delegate.representations.filter { !$0.segments.isEmpty }
        guard !candidates.isEmpty else { throw MediaDownloadError.noSegments }
        let eligible = candidates.filter { $0.height == 0 || $0.height <= preferredHeight }
        let chosen = (eligible.isEmpty ? candidates : eligible).max {
            ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth)
        }!
        return ResolvedMediaManifest(segments: chosen.segments, fileExtension: "mp4")
    }

    private func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw MediaDownloadError.invalidResponse(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw MediaDownloadError.invalidManifest }
        return text
    }

    private func parseAttributes(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var quoted = false
        var parts: [String] = []
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return result
    }

    private func rangeHeader(_ value: String?, offset: inout Int64) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: "@", maxSplits: 1)
        guard let length = Int64(parts[0]), length > 0 else { return nil }
        if parts.count == 2 { offset = Int64(parts[1]) ?? offset }
        let range = "\(offset)-\(offset + length - 1)"
        offset += length
        return range
    }

    private func loadCheckpoint(_ url: URL, sourceURL: URL) -> MediaCheckpoint {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(MediaCheckpoint.self, from: data),
              value.sourceURL == sourceURL else {
            return MediaCheckpoint(sourceURL: sourceURL, completedSegments: 0, downloadedBytes: 0)
        }
        return value
    }

    private func persist(_ checkpoint: MediaCheckpoint, to url: URL) throws {
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }

    private func defaultFilename(for sourceURL: URL) -> String {
        let value = sourceURL.deletingPathExtension().lastPathComponent
        return value.isEmpty ? "Media" : value
    }
}

private struct DASHRepresentation: Sendable {
    let height: Int
    let bandwidth: Int
    var segments: [MediaSegment]
}

private final class DASHParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    let manifestURL: URL
    var representations: [DASHRepresentation] = []
    private var current: DASHRepresentation?
    private var currentBaseURL: URL
    private var collectingBaseURL = false
    private var baseURLText = ""

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
        currentBaseURL = manifestURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Representation":
            current = DASHRepresentation(
                height: Int(attributeDict["height"] ?? "0") ?? 0,
                bandwidth: Int(attributeDict["bandwidth"] ?? "0") ?? 0,
                segments: []
            )
            currentBaseURL = manifestURL
        case "BaseURL":
            collectingBaseURL = true
            baseURLText = ""
        case "Initialization":
            append(attributeDict["sourceURL"])
        case "SegmentURL":
            append(attributeDict["media"], range: attributeDict["mediaRange"])
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingBaseURL { baseURLText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "BaseURL" {
            collectingBaseURL = false
            let value = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value, relativeTo: manifestURL)?.absoluteURL { currentBaseURL = url }
        } else if elementName == "Representation", let current {
            representations.append(current)
            self.current = nil
        }
    }

    private func append(_ value: String?, range: String? = nil) {
        guard let value, var current,
              let url = URL(string: value, relativeTo: currentBaseURL)?.absoluteURL else { return }
        current.segments.append(MediaSegment(url: url, byteRange: range))
        self.current = current
    }
}

private extension URL {
    func appendingPathExtensionIfMissing(_ pathExtension: String) -> URL {
        self.pathExtension.isEmpty ? appendingPathExtension(pathExtension) : self
    }
}
