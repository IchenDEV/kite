import Foundation

enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case active
    case waiting
    case paused
    case error
    case complete
    case removed
    case sharing
    case unknown

    var title: String {
        switch self {
        case .active: "Downloading"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .error: "Failed"
        case .complete: "Completed"
        case .removed: "Removed"
        case .sharing: "Sharing"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "arrow.down.circle.fill"
        case .waiting: "clock"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle.fill"
        case .removed: "trash"
        case .sharing: "arrow.up.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var isTerminal: Bool { self == .complete || self == .error || self == .removed }
}

struct DownloadURI: Codable, Hashable, Sendable {
    let uri: String
    let status: String
}

struct DownloadFile: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let path: String
    let length: Int64
    let completedLength: Int64
    let selected: Bool
    let uris: [DownloadURI]

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var progress: Double { length > 0 ? min(Double(completedLength) / Double(length), 1) : 0 }

    init(json: [String: JSONValue]) {
        id = Int(json.string("index") ?? "0") ?? 0
        path = json.string("path") ?? ""
        length = json.int64("length")
        completedLength = json.int64("completedLength")
        selected = (json.string("selected") ?? "true") == "true"
        uris = json.array("uris").compactMap { value in
            guard let object = value.objectValue, let uri = object.string("uri") else { return nil }
            return DownloadURI(uri: uri, status: object.string("status") ?? "")
        }
    }
}

struct DownloadTask: Codable, Identifiable, Hashable, Sendable {
    var id: String { gid }

    let gid: String
    let status: DownloadStatus
    let totalLength: Int64
    let completedLength: Int64
    let uploadLength: Int64
    let downloadSpeed: Int64
    let uploadSpeed: Int64
    let connections: Int
    let errorCode: String?
    let errorMessage: String?
    let directory: String
    let files: [DownloadFile]
    let bitTorrentName: String?
    let infoHash: String?
    let trackers: [String]
    let numSeeders: Int
    let seeder: Bool
    let pieceLength: Int64
    let numPieces: Int
    let completedPieces: String?
    let followedBy: [String]

    var name: String {
        if let bitTorrentName, !bitTorrentName.isEmpty { return bitTorrentName }
        if let firstPath = files.first?.path, !firstPath.isEmpty {
            return URL(fileURLWithPath: firstPath).lastPathComponent
        }
        if let firstURI = files.first?.uris.first?.uri,
           let components = URLComponents(string: firstURI),
           let last = components.path.split(separator: "/").last {
            return String(last).removingPercentEncoding ?? String(last)
        }
        return gid
    }

    var progress: Double {
        totalLength > 0 ? min(Double(completedLength) / Double(totalLength), 1) : 0
    }

    var remainingLength: Int64 { max(totalLength - completedLength, 0) }
    var estimatedSecondsRemaining: TimeInterval? {
        guard downloadSpeed > 0, remainingLength > 0 else { return nil }
        return TimeInterval(remainingLength) / TimeInterval(downloadSpeed)
    }
    var isBitTorrent: Bool { infoHash != nil || bitTorrentName != nil }
    var primaryFileURL: URL? { files.first.map { URL(fileURLWithPath: $0.path) } }

    init(json: [String: JSONValue]) {
        gid = json.string("gid") ?? UUID().uuidString
        status = DownloadStatus(rawValue: json.string("status") ?? "") ?? .unknown
        totalLength = json.int64("totalLength")
        completedLength = json.int64("completedLength")
        uploadLength = json.int64("uploadLength")
        downloadSpeed = json.int64("downloadSpeed")
        uploadSpeed = json.int64("uploadSpeed")
        connections = Int(json.string("connections") ?? "0") ?? 0
        errorCode = json.string("errorCode")
        errorMessage = json.string("errorMessage")
        directory = json.string("dir") ?? ""
        files = json.array("files").compactMap { $0.objectValue }.map(DownloadFile.init)
        bitTorrentName = json.object("bittorrent")?.object("info")?.string("name")
        infoHash = json.string("infoHash")
        trackers = json.object("bittorrent")?.array("announceList")
            .flatMap { $0.arrayValue ?? [] }
            .compactMap(\.stringValue) ?? []
        numSeeders = Int(json.string("numSeeders") ?? "0") ?? 0
        seeder = json.string("seeder") == "true"
        pieceLength = json.int64("pieceLength")
        numPieces = Int(json.string("numPieces") ?? "0") ?? 0
        completedPieces = json.string("bitfield")
        followedBy = json.array("followedBy").compactMap(\.stringValue)
    }

    static func media(
        gid: String,
        status: DownloadStatus,
        sourceURL: String,
        outputPath: String,
        completedLength: Int64 = 0,
        totalLength: Int64 = 0,
        downloadSpeed: Int64 = 0,
        errorMessage: String? = nil
    ) -> DownloadTask {
        var json: [String: JSONValue] = [
            "gid": .string(gid),
            "status": .string(status.rawValue),
            "totalLength": .string(String(totalLength)),
            "completedLength": .string(String(completedLength)),
            "downloadSpeed": .string(String(downloadSpeed)),
            "dir": .string(URL(fileURLWithPath: outputPath).deletingLastPathComponent().path),
            "files": .array([
                .object([
                    "index": .string("1"),
                    "path": .string(outputPath),
                    "length": .string(String(totalLength)),
                    "completedLength": .string(String(completedLength)),
                    "selected": .string("true"),
                    "uris": .array([.object(["uri": .string(sourceURL), "status": .string("used")])]),
                ]),
            ]),
        ]
        if let errorMessage { json["errorMessage"] = .string(errorMessage) }
        return DownloadTask(json: json)
    }
}

struct Peer: Identifiable, Hashable, Sendable {
    var id: String { "\(ip):\(port)" }
    let peerID: String
    let ip: String
    let port: Int
    let client: String
    let downloadSpeed: Int64
    let uploadSpeed: Int64
    let bitfield: String
    let amChoking: Bool
    let peerChoking: Bool
    let seeder: Bool

    init(json: [String: JSONValue]) {
        peerID = json.string("peerId") ?? ""
        ip = json.string("ip") ?? ""
        port = Int(json.string("port") ?? "0") ?? 0
        client = json.string("client") ?? ""
        downloadSpeed = json.int64("downloadSpeed")
        uploadSpeed = json.int64("uploadSpeed")
        bitfield = json.string("bitfield") ?? ""
        amChoking = json.string("amChoking") == "true"
        peerChoking = json.string("peerChoking") == "true"
        seeder = json.string("seeder") == "true"
    }
}

struct GlobalStat: Equatable, Sendable {
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0
    var numActive = 0
    var numWaiting = 0
    var numStopped = 0

    init() {}

    init(json: [String: JSONValue]) {
        downloadSpeed = json.int64("downloadSpeed")
        uploadSpeed = json.int64("uploadSpeed")
        numActive = Int(json.string("numActive") ?? "0") ?? 0
        numWaiting = Int(json.string("numWaiting") ?? "0") ?? 0
        numStopped = Int(json.string("numStopped") ?? "0") ?? 0
    }
}

struct SpeedSample: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let download: Int64
    let upload: Int64
}

struct HistoryRecord: Identifiable, Sendable {
    let id: String
    let name: String
    let status: DownloadStatus
    let totalLength: Int64
    let completedLength: Int64
    let directory: String
    let completedAt: Date
    let sourceURL: String?
    let sourceFilePath: String?
    let retryOptions: [String: JSONValue]
    let errorMessage: String?
    let label: String

    var canRetry: Bool {
        sourceURL?.isEmpty == false || sourceFilePath?.isEmpty == false
    }
}
