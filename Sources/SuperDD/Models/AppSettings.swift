import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    struct FileCategory: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var extensions: [String]
        var directory: String
    }

    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case system
        case manual

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    struct SpeedSchedule: Codable, Equatable, Sendable {
        var enabled = false
        var startHour = 8
        var endHour = 18
        var downloadLimit = "0"
        var uploadLimit = "0"
        /// ISO weekday numbers, Monday = 1 and Sunday = 7.
        var weekdays = Set(1 ... 7)
    }

    var appearance: Appearance = .system
    var downloadDirectory: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    var maxConcurrentDownloads = 6
    var split = 16
    var maxConnectionsPerServer = 16
    var globalDownloadLimit = "0"
    var globalUploadLimit = "0"
    var perTaskDownloadLimit = "0"
    var perTaskUploadLimit = "0"
    var continueDownloads = true
    var fileAllocation = "none"
    var autoFileRenaming = true
    var favoriteDirectories: [String] = []
    var recentDirectories: [String] = []
    var fileCategorizationEnabled = false
    var fileCategories: [FileCategory] = []

    var btListenPort = 29_120
    var dhtListenPort = 29_130
    var ed2kListenPort = 29_140
    var ed2kUDPListenPort = 29_150
    var btMaxPeers = 128
    var enableDHT = true
    var enableDHT6 = true
    var enablePeerExchange = true
    var enableLocalPeerDiscovery = true
    var forceEncryption = false
    var seedRatio = 2.0
    var seedTimeMinutes = 2_880
    var pauseMetadata = true
    var trackerURLs = [
        "https://ngosang.github.io/trackerslist/trackers_best.txt",
        "https://cf.trackerslist.com/best.txt",
    ]
    var enablePeerBlocklist = true
    var peerBlocklistURL = "https://bcr.pbh-btn.com/combine/all.txt"
    var ed2kServerListURL = "https://upd.emule-security.org/server.met"
    var ed2kNodeListURL = "https://upd.emule-security.org/nodes.dat"

    var proxyMode: ProxyMode = .none
    var proxyURL = ""
    var proxyUsername = ""
    var proxyPassword = ""
    var userAgent = "SuperDD/0.1 aria2-next"
    var rpcPort = 29_100

    var notificationsEnabled = true
    var showDockBadge = true
    var preventSleepWhileDownloading = true
    var startAtLogin = false
    var extensionServerEnabled = true
    var extensionServerPort = 29_110
    var extensionSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var speedSchedule = SpeedSchedule()
}

struct AddTaskOptions: Sendable {
    var directory: String
    var filename = ""
    var referer = ""
    var userAgent = ""
    var cookie = ""
    var headers = ""
    var checksum = ""
    var proxy = ""
    var paused = false

    init(directory: String) {
        self.directory = directory
    }

    var aria2Options: [String: JSONValue] {
        var result: [String: JSONValue] = ["dir": .string(directory)]
        if !filename.isEmpty { result["out"] = .string(filename) }
        if !referer.isEmpty { result["referer"] = .string(referer) }
        if !userAgent.isEmpty { result["user-agent"] = .string(userAgent) }
        if !cookie.isEmpty { result["header"] = .array([.string("Cookie: \(cookie)")]) }
        if !headers.isEmpty {
            let existing = result["header"]?.arrayValue ?? []
            let additional = headers
                .split(whereSeparator: \.isNewline)
                .map { JSONValue.string(String($0)) }
            result["header"] = .array(existing + additional)
        }
        if !checksum.isEmpty { result["checksum"] = .string(checksum) }
        if !proxy.isEmpty { result["all-proxy"] = .string(proxy) }
        if paused { result["pause"] = .string("true") }
        return result
    }
}
