import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class DownloadStore {
    var section: AppSection = .all
    var selectedTaskIDs = Set<String>()
    var selectedHistoryIDs = Set<String>()
    var searchText = ""
    var showingAddTask = false
    var showingInspector = false
    var engineState: EngineState = .stopped
    var activeTasks: [DownloadTask] = []
    var waitingTasks: [DownloadTask] = []
    var stoppedTasks: [DownloadTask] = []
    var history: [HistoryRecord] = []
    var peers: [Peer] = []
    var globalStat = GlobalStat()
    var speedSamples: [SpeedSample] = []
    var extensionAPIPort: Int?
    var trackerCount = 0
    var lastError: String?
    var isBusy = false

    let settingsStore: SettingsStore

    private let engine = Aria2Engine()
    private let historyStore: HistoryStore?
    private let notificationService = NotificationService()
    private let powerService = PowerAssertionService()
    private let extensionServer = ExtensionServer()
    private let trackerService = TrackerService()
    private let diagnosticsService = DiagnosticsService()
    private let logger = Logger(subsystem: "com.chenli.superdd", category: "downloads")
    private var client: Aria2RPCClient?
    private var pollingTask: Task<Void, Never>?
    private var recordedTerminalGIDs = Set<String>()
    private var didCompleteInitialRefresh = false
    private var appliedScheduledLimits: (String, String)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        historyStore = try? HistoryStore()
    }

    var allTasks: [DownloadTask] {
        activeTasks + waitingTasks + stoppedTasks
    }

    var visibleTasks: [DownloadTask] {
        let base: [DownloadTask]
        switch section {
        case .dashboard, .all: base = allTasks
        case .downloading: base = activeTasks
        case .waiting: base = waitingTasks.filter { $0.status == .waiting || $0.status == .paused }
        case .completed: base = stoppedTasks.filter { $0.status == .complete }
        case .failed: base = stoppedTasks.filter { $0.status == .error }
        case .history: base = []
        }
        guard !searchText.isEmpty else { return base }
        return base.filter { task in
            task.name.localizedStandardContains(searchText)
                || task.gid.localizedStandardContains(searchText)
                || task.files.contains { $0.path.localizedStandardContains(searchText) }
        }
    }

    var visibleHistory: [HistoryRecord] {
        guard !searchText.isEmpty else { return history }
        return history.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.directory.localizedStandardContains(searchText)
        }
    }

    var selectedTask: DownloadTask? {
        guard selectedTaskIDs.count == 1, let id = selectedTaskIDs.first else { return nil }
        return allTasks.first { $0.gid == id }
    }

    var selectedTasks: [DownloadTask] {
        allTasks.filter { selectedTaskIDs.contains($0.gid) }
    }

    var selectedHistoryRecord: HistoryRecord? {
        guard selectedHistoryIDs.count == 1, let id = selectedHistoryIDs.first else { return nil }
        return history.first { $0.id == id }
    }

    var canPauseSelection: Bool {
        selectedTasks.contains { $0.status == .active || $0.status == .waiting || $0.status == .sharing }
    }

    var canResumeSelection: Bool {
        selectedTasks.contains { $0.status == .paused }
    }

    func start() async {
        guard client == nil else { return }
        engineState = .starting
        Task { [notificationService, settingsStore] in
            await notificationService.requestAuthorizationIfNeeded(enabled: settingsStore.values.notificationsEnabled)
        }
        await loadHistory()

        do {
            let started = try await engine.start(settings: settingsStore.values)
            client = started.client
            engineState = .running(version: started.version)
            await configureExtensionServer(client: started.client, engineVersion: started.version)
            Task { await self.synchronizeTrackers(client: started.client) }
            lastError = nil
            await refresh()
            beginPolling()
        } catch {
            engineState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
        await engine.stop(client: client)
        await extensionServer.stop()
        extensionAPIPort = nil
        client = nil
        engineState = .stopped
        await powerService.update(activeDownloads: 0, enabled: false)
    }

    func restartEngine() async {
        isBusy = true
        pollingTask?.cancel()
        settingsStore.save()
        do {
            let restarted = try await engine.restart(settings: settingsStore.values, client: client)
            client = restarted.client
            engineState = .running(version: restarted.version)
            await configureExtensionServer(client: restarted.client, engineVersion: restarted.version)
            Task { await self.synchronizeTrackers(client: restarted.client) }
            lastError = nil
            await refresh()
            beginPolling()
        } catch {
            engineState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    func refresh() async {
        guard let client else { return }
        do {
            async let active = client.tellActive()
            async let waiting = client.tellWaiting()
            async let stopped = client.tellStopped()
            async let stat = client.globalStat()
            let values = try await (active, waiting, stopped, stat)
            activeTasks = values.0
            waitingTasks = values.1
            stoppedTasks = values.2
            globalStat = values.3
            appendSpeedSample(stat: values.3)
            trimInvalidSelection()
            await persistNewTerminalTasks(values.2)
            await updateSystemState()
            await applySpeedScheduleIfNeeded()
            if didCompleteInitialRefresh {
                await notificationService.process(tasks: values.2, enabled: settingsStore.values.notificationsEnabled)
            } else {
                didCompleteInitialRefresh = true
            }
            if selectedTask?.isBitTorrent == true {
                await refreshPeers()
            } else {
                peers = []
            }
            lastError = nil
        } catch {
            logger.error("Refresh failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func addURLs(_ rawURLs: [String], options: AddTaskOptions) async {
        guard let client else { return }
        isBusy = true
        do {
            for rawURL in rawURLs {
                guard let url = DownloadURLNormalizer.normalize(rawURL) else { continue }
                var routedOptions = options
                routedOptions.directory = categorizedDirectory(for: url, options: options)
                var aria2Options = routedOptions.aria2Options
                if aria2Options["user-agent"] == nil {
                    aria2Options["user-agent"] = .string(settingsStore.values.userAgent)
                }
                _ = try await client.addURI(url, options: aria2Options)
            }
            showingAddTask = false
            recordRecentDirectory(options.directory)
            section = .all
            try await Task.sleep(for: .milliseconds(150))
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    func addTorrent(at url: URL, options: AddTaskOptions? = nil) async {
        guard let client else { return }
        isBusy = true
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let taskOptions = options ?? AddTaskOptions(directory: settingsStore.values.downloadDirectory)
            _ = try await client.addTorrent(data: data, options: taskOptions.aria2Options)
            showingAddTask = false
            recordRecentDirectory(taskOptions.directory)
            section = .all
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    func handleExternalURL(_ url: URL) async {
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            await addTorrent(at: url)
            return
        }
        var options = AddTaskOptions(directory: settingsStore.values.downloadDirectory)
        options.userAgent = settingsStore.values.userAgent
        await addURLs([url.absoluteString], options: options)
    }

    func pauseSelection() async {
        await runSelected { client, task in
            guard task.status == .active || task.status == .waiting || task.status == .sharing else { return }
            try await client.pause(gid: task.gid)
        }
    }

    func resumeSelection() async {
        await runSelected { client, task in
            guard task.status == .paused else { return }
            try await client.resume(gid: task.gid)
        }
    }

    func togglePauseSelection() async {
        if canPauseSelection { await pauseSelection() }
        else if canResumeSelection { await resumeSelection() }
    }

    func removeSelection() async {
        await runSelected { client, task in
            if task.status.isTerminal {
                try await client.removeResult(gid: task.gid)
            } else {
                try await client.remove(gid: task.gid, force: task.status == .active)
            }
        }
        selectedTaskIDs.removeAll()
    }

    func removeHistorySelection() async {
        guard let historyStore else { return }
        for id in selectedHistoryIDs {
            try? await historyStore.remove(id: id)
        }
        selectedHistoryIDs.removeAll()
        await loadHistory()
    }

    func clearHistory() async {
        try? await historyStore?.removeAll()
        history = []
        selectedHistoryIDs.removeAll()
    }

    func setSelectedFiles(_ indices: Set<Int>, task: DownloadTask) async {
        guard let client else { return }
        do {
            let value = indices.sorted().map(String.init).joined(separator: ",")
            try await client.changeOption(gid: task.gid, options: ["select-file": .string(value)])
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reveal(_ task: DownloadTask) {
        guard let url = task.primaryFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ task: DownloadTask) {
        guard let url = task.primaryFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copySourceURL(_ task: DownloadTask) {
        guard let uri = task.files.first?.uris.first?.uri else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri, forType: .string)
    }

    func showInFinder(_ record: HistoryRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.directory)])
    }

    func exportDiagnostics(to destination: URL) async {
        do {
            let integrity = try await historyStore?.integrityCheck() ?? "history database unavailable"
            try await diagnosticsService.export(
                to: destination,
                settings: settingsStore.values,
                historyIntegrity: integrity
            )
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleFavoriteDirectory(_ directory: String) {
        guard !directory.isEmpty else { return }
        if let index = settingsStore.values.favoriteDirectories.firstIndex(of: directory) {
            settingsStore.values.favoriteDirectories.remove(at: index)
        } else {
            settingsStore.values.favoriteDirectories.insert(directory, at: 0)
            settingsStore.values.favoriteDirectories = Array(settingsStore.values.favoriteDirectories.prefix(10))
        }
        settingsStore.save()
    }

    func count(for section: AppSection) -> Int? {
        switch section {
        case .dashboard: nil
        case .all: allTasks.count
        case .downloading: activeTasks.count
        case .waiting: waitingTasks.count
        case .completed: stoppedTasks.count { $0.status == .complete }
        case .failed: stoppedTasks.count { $0.status == .error }
        case .history: history.count
        }
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func runSelected(_ operation: (Aria2RPCClient, DownloadTask) async throws -> Void) async {
        guard let client else { return }
        isBusy = true
        do {
            for task in selectedTasks { try await operation(client, task) }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    private func refreshPeers() async {
        guard let client, let task = selectedTask, task.isBitTorrent else { return }
        peers = (try? await client.peers(gid: task.gid)) ?? []
    }

    private func appendSpeedSample(stat: GlobalStat) {
        speedSamples.append(SpeedSample(date: .now, download: stat.downloadSpeed, upload: stat.uploadSpeed))
        if speedSamples.count > 120 { speedSamples.removeFirst(speedSamples.count - 120) }
    }

    private func trimInvalidSelection() {
        let valid = Set(allTasks.map(\.gid))
        selectedTaskIDs.formIntersection(valid)
    }

    private func persistNewTerminalTasks(_ tasks: [DownloadTask]) async {
        guard let historyStore else { return }
        for task in tasks where task.status.isTerminal && !recordedTerminalGIDs.contains(task.gid) {
            try? await historyStore.upsert(task: task)
            recordedTerminalGIDs.insert(task.gid)
        }
        await loadHistory()
    }

    private func loadHistory() async {
        guard let historyStore else { return }
        history = (try? await historyStore.records()) ?? []
        recordedTerminalGIDs.formUnion(history.map(\.id))
    }

    private func updateSystemState() async {
        await powerService.update(
            activeDownloads: activeTasks.count,
            enabled: settingsStore.values.preventSleepWhileDownloading
        )
        if settingsStore.values.showDockBadge {
            NSApp.dockTile.badgeLabel = activeTasks.isEmpty ? nil : String(activeTasks.count)
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private func applySpeedScheduleIfNeeded(date: Date = .now) async {
        guard let client else { return }
        let schedule = settingsStore.values.speedSchedule
        let weekday = Calendar.current.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        let hour = Calendar.current.component(.hour, from: date)
        let inHourRange: Bool = if schedule.startHour <= schedule.endHour {
            (schedule.startHour ..< schedule.endHour).contains(hour)
        } else {
            hour >= schedule.startHour || hour < schedule.endHour
        }
        let scheduled = schedule.enabled && schedule.weekdays.contains(isoWeekday) && inHourRange
        let limits = scheduled
            ? (schedule.downloadLimit, schedule.uploadLimit)
            : (settingsStore.values.globalDownloadLimit, settingsStore.values.globalUploadLimit)
        guard appliedScheduledLimits?.0 != limits.0 || appliedScheduledLimits?.1 != limits.1 else { return }
        do {
            try await client.changeGlobalOption([
                "max-overall-download-limit": .string(limits.0),
                "max-overall-upload-limit": .string(limits.1),
            ])
            appliedScheduledLimits = limits
        } catch {
            logger.warning("Could not apply scheduled speed limits: \(error.localizedDescription)")
        }
    }

    private func configureExtensionServer(client: Aria2RPCClient, engineVersion: String) async {
        guard settingsStore.values.extensionServerEnabled else {
            await extensionServer.stop()
            extensionAPIPort = nil
            return
        }
        do {
            extensionAPIPort = try await extensionServer.start(
                preferredPort: settingsStore.values.extensionServerPort,
                settings: settingsStore.values,
                client: client,
                engineVersion: engineVersion
            )
        } catch {
            extensionAPIPort = nil
            logger.warning("Extension API could not start: \(error.localizedDescription)")
        }
    }

    private func synchronizeTrackers(client: Aria2RPCClient) async {
        trackerCount = await trackerService.synchronize(sources: settingsStore.values.trackerURLs, client: client)
    }

    private func recordRecentDirectory(_ directory: String) {
        guard !directory.isEmpty else { return }
        settingsStore.values.recentDirectories.removeAll { $0 == directory }
        settingsStore.values.recentDirectories.insert(directory, at: 0)
        settingsStore.values.recentDirectories = Array(settingsStore.values.recentDirectories.prefix(5))
        settingsStore.save()
    }

    private func categorizedDirectory(for source: String, options: AddTaskOptions) -> String {
        let settings = settingsStore.values
        guard settings.fileCategorizationEnabled,
              options.directory == settings.downloadDirectory else { return options.directory }
        let candidateName = options.filename.isEmpty
            ? URLComponents(string: source)?.path.split(separator: "/").last.map(String.init) ?? ""
            : options.filename
        let ext = URL(fileURLWithPath: candidateName).pathExtension.lowercased()
        guard !ext.isEmpty,
              let category = settings.fileCategories.first(where: { $0.extensions.map { $0.lowercased() }.contains(ext) }) else {
            return options.directory
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: category.directory), withIntermediateDirectories: true)
        return category.directory
    }
}
