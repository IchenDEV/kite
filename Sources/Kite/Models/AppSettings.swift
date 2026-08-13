import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
        case rename
        case overwrite
        case skip

        var id: String { rawValue }
        var title: String {
            switch self {
            case .rename: "Keep Both"
            case .overwrite: "Replace Existing File"
            case .skip: "Skip Existing File"
            }
        }
    }

    enum CompletionAction: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case quit
        case sleep
        case shutDown

        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Do Nothing"
            case .quit: "Quit Kite"
            case .sleep: "Put Mac to Sleep"
            case .shutDown: "Shut Down Mac"
            }
        }
    }

    struct CredentialProfile: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var hostPattern: String
        var username: String
        var sendsCookie = false
    }

    struct RSSFeed: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var url: String
        var enabled = true
        var lastCheckedAt: Date?
    }

    struct RSSRule: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var feedID: UUID?
        var titlePattern: String
        var destination: String
        var label = "RSS"
        var paused = false
        var enabled = true
    }

    struct SearchProvider: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        /// URL template containing a literal `{query}` placeholder.
        var urlTemplate: String
        var enabled = true
    }

    struct FeatureSettings: Codable, Equatable, Sendable {
        struct Capture: Codable, Equatable, Sendable {
            var monitorClipboard = true
            var confirmClipboardLinks = true
            var ignoredHosts: [String] = []
        }

        struct Reliability: Codable, Equatable, Sendable {
            var maxTries = 5
            var retryWaitSeconds = 5
            var automaticRetry = true
            var checkIntegrity = true
            var conflictPolicy: ConflictPolicy = .rename
        }

        struct TaskSchedule: Codable, Equatable, Sendable {
            var enabled = false
            var startHour = 0
            var endHour = 24
            var weekdays = Set(1 ... 7)
            var pauseOutsideWindow = false
            var completionAction: CompletionAction = .none
            var completionCountdownSeconds = 30
        }

        struct PostProcessing: Codable, Equatable, Sendable {
            var autoExtractArchives = false
            var deleteArchiveAfterExtraction = false
            var extractionSubdirectory = ""
            var revealCompletedFiles = false
            var openCompletedFiles = false
            var command = ""
        }

        struct Media: Codable, Equatable, Sendable {
            var resolveStreamingManifests = true
            var preferredHeight = 1_080
            var preferredAudioLanguage = ""
            var preferredSubtitleLanguages: [String] = []
            var downloadSubtitles = true
            var audioOnly = false
        }

        struct NetworkPolicy: Codable, Equatable, Sendable {
            var bindInterface = ""
            var noDirectFallback = false
            var enableUPnP = false
            var enableNATPMP = false
            var geoIPDatabaseURL = ""
        }

        struct Remote: Codable, Equatable, Sendable {
            var enabled = false
            var allowLAN = false
            var port = 29_120
            var secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        struct TorrentAutomation: Codable, Equatable, Sendable {
            var watchDirectory = ""
            var watchIntervalSeconds = 15
            var rssCheckIntervalMinutes = 15
            var feeds: [RSSFeed] = []
            var rules: [RSSRule] = []
            var searchProviders: [SearchProvider] = []
        }

        struct Plugins: Codable, Equatable, Sendable {
            var enabled = true
            var registryURL = "https://motrix.app/plugins"
            var allowNetworkAccessByDefault = false
        }

        struct Updates: Codable, Equatable, Sendable {
            var automaticallyChecks = true
            var feedURL = "https://api.github.com/repos/IchenDEV/kite/releases/latest"
            var lastCheckedAt: Date?
        }

        var capture = Capture()
        var reliability = Reliability()
        var taskSchedule = TaskSchedule()
        var postProcessing = PostProcessing()
        var media = Media()
        var networkPolicy = NetworkPolicy()
        var remote = Remote()
        var torrentAutomation = TorrentAutomation()
        var plugins = Plugins()
        var updates = Updates()
        var credentialProfiles: [CredentialProfile] = []
    }

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
    var userAgent = "Kite/0.2 aria2-next"
    var rpcPort = 29_100

    var notificationsEnabled = true
    var showDockBadge = true
    var preventSleepWhileDownloading = true
    var startAtLogin = false
    var extensionServerEnabled = true
    var extensionServerPort = 29_110
    var extensionSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var speedSchedule = SpeedSchedule()
    /// Optional for backward-compatible decoding of settings written by 0.1.x.
    var featureSettings: FeatureSettings? = FeatureSettings()

    var features: FeatureSettings {
        get { featureSettings ?? FeatureSettings() }
        set { featureSettings = newValue }
    }
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
    var selectedFileIndices: Set<Int>?
    var paused = false
    var credentialProfileID: UUID?
    var label = ""
    var scheduled = false
    var priority: TaskPriority = .normal

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
        if let selectedFileIndices, !selectedFileIndices.isEmpty {
            result["select-file"] = .string(selectedFileIndices.sorted().map(String.init).joined(separator: ","))
        }
        if paused { result["pause"] = .string("true") }
        return result
    }
}
