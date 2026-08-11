import Foundation
import OSLog

enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running(version: String)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting Engine"
        case let .running(version): version.isEmpty ? "Connected" : "aria2-next \(version)"
        case .failed: "Engine Error"
        }
    }
}

struct Aria2EngineConfiguration: Sendable {
    let executableURL: URL
    let supportDirectory: URL
    let settings: AppSettings
    let secret: String
    let rpcPort: Int
    let portOffset: Int
    let resources: EngineResources
}

actor Aria2Engine {
    private var process: Process?
    private var runningPort: Int?
    private let logger = Logger(subsystem: "com.chenli.superdd", category: "engine")

    func start(settings: AppSettings) async throws -> (client: Aria2RPCClient, version: String) {
        if let process, process.isRunning {
            let client = Aria2RPCClient(port: runningPort ?? settings.rpcPort, secret: Self.rpcSecret)
            return (client, try await version(using: client))
        }

        let executableURL = try Self.resolveExecutable()
        let supportDirectory = try Self.prepareSupportDirectory()
        let resources = await EngineResourceService.prepare(in: supportDirectory, settings: settings)
        let rpcPort = try LocalPortResolver.available(startingAt: settings.rpcPort)
        let configuration = Aria2EngineConfiguration(
            executableURL: executableURL,
            supportDirectory: supportDirectory,
            settings: settings,
            secret: Self.rpcSecret,
            rpcPort: rpcPort,
            portOffset: rpcPort - settings.rpcPort,
            resources: resources
        )

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = supportDirectory
        process.arguments = Self.arguments(for: configuration)

        let logURL = supportDirectory.appending(path: "aria2-next.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        logger.info("Starting aria2-next on RPC port \(rpcPort)")
        try process.run()
        self.process = process
        runningPort = rpcPort

        let client = Aria2RPCClient(port: rpcPort, secret: Self.rpcSecret)
        var lastError: Error = URLError(.cannotConnectToHost)
        for _ in 0 ..< 50 {
            if !process.isRunning {
                throw Aria2RPCError(code: Int(process.terminationStatus), message: "aria2-next exited during startup. See \(logURL.path)")
            }
            do {
                return (client, try await version(using: client))
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        process.terminate()
        self.process = nil
        throw lastError
    }

    func stop(client: Aria2RPCClient?) async {
        if let client {
            try? await client.saveSession()
            try? await client.shutdown()
        }
        if let process, process.isRunning {
            for _ in 0 ..< 20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
        }
        process = nil
        runningPort = nil
    }

    func restart(settings: AppSettings, client: Aria2RPCClient?) async throws -> (client: Aria2RPCClient, version: String) {
        await stop(client: client)
        return try await start(settings: settings)
    }

    private func version(using client: Aria2RPCClient) async throws -> String {
        let value = try await client.call("aria2.getVersion")
        return value.objectValue?.string("version") ?? ""
    }

    private static let rpcSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private static func resolveExecutable() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SUPERDD_ARIA2_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: "Engine/aria2-next"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Engine/aria2-next"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/aria2-next"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/aria2c"))

        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "aria2-next is missing. Run script/fetch_engine.sh, then relaunch Super DD."])
    }

    private static func prepareSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "SuperDD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = directory.appending(path: "aria2.session")
        if !FileManager.default.fileExists(atPath: session.path) {
            FileManager.default.createFile(atPath: session.path, contents: nil)
        }
        return directory
    }

    private static func arguments(for configuration: Aria2EngineConfiguration) -> [String] {
        let settings = configuration.settings
        let sessionPath = configuration.supportDirectory.appending(path: "aria2.session").path
        var arguments = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(configuration.rpcPort)",
            "--rpc-secret=\(configuration.secret)",
            "--rpc-max-request-size=64M",
            "--dir=\(settings.downloadDirectory)",
            "--input-file=\(sessionPath)",
            "--save-session=\(sessionPath)",
            "--save-session-interval=30",
            "--auto-save-interval=30",
            "--continue=\(settings.continueDownloads)",
            "--max-concurrent-downloads=\(settings.maxConcurrentDownloads)",
            "--split=\(settings.split)",
            "--max-connection-per-server=\(settings.maxConnectionsPerServer)",
            "--max-overall-download-limit=\(settings.globalDownloadLimit)",
            "--max-overall-upload-limit=\(settings.globalUploadLimit)",
            "--max-download-limit=\(settings.perTaskDownloadLimit)",
            "--max-upload-limit=\(settings.perTaskUploadLimit)",
            "--file-allocation=\(settings.fileAllocation)",
            "--auto-file-renaming=\(settings.autoFileRenaming)",
            "--user-agent=\(settings.userAgent)",
            "--listen-port=\(settings.btListenPort + configuration.portOffset)",
            "--dht-listen-port=\(settings.dhtListenPort + configuration.portOffset)",
            "--ed2k-listen-port=\(settings.ed2kListenPort + configuration.portOffset)",
            "--ed2k-udp-listen-port=\(settings.ed2kUDPListenPort + configuration.portOffset)",
            "--enable-dht=\(settings.enableDHT)",
            "--enable-dht6=\(settings.enableDHT6)",
            "--enable-peer-exchange=\(settings.enablePeerExchange)",
            "--bt-enable-lpd=\(settings.enableLocalPeerDiscovery)",
            "--bt-force-encryption=\(settings.forceEncryption)",
            "--bt-max-peers=\(settings.btMaxPeers)",
            "--seed-ratio=\(settings.seedRatio)",
            "--seed-time=\(settings.seedTimeMinutes)",
            "--pause-metadata=\(settings.pauseMetadata)",
            "--check-certificate=true",
            "--content-disposition-default-utf8=true",
            "--download-result=full",
            "--keep-unfinished-download-result=true",
            "--max-download-result=1000",
            "--console-log-level=warn",
            "--summary-interval=0",
        ]

        let proxy = resolvedProxy(settings: settings)
        if !proxy.isEmpty { arguments.append("--all-proxy=\(proxy)") }
        if !settings.proxyUsername.isEmpty { arguments.append("--all-proxy-user=\(settings.proxyUsername)") }
        if !settings.proxyPassword.isEmpty { arguments.append("--all-proxy-passwd=\(settings.proxyPassword)") }
        if let url = configuration.resources.ed2kServerList { arguments.append("--ed2k-server-list=\(url.path)") }
        if let url = configuration.resources.ed2kNodeList { arguments.append("--ed2k-node-list=\(url.path)") }
        if let url = configuration.resources.peerBlocklist { arguments.append("--bt-peer-blocklist=\(url.path)") }
        return arguments
    }

    private static func resolvedProxy(settings: AppSettings) -> String {
        switch settings.proxyMode {
        case .none: ""
        case .manual: settings.proxyURL
        case .system:
            ProcessInfo.processInfo.environment["HTTPS_PROXY"]
                ?? ProcessInfo.processInfo.environment["HTTP_PROXY"]
                ?? ProcessInfo.processInfo.environment["ALL_PROXY"]
                ?? ""
        }
    }

}
