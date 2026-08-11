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
    var showingTorrentCreator = false
    var showingInspector = false
    var engineState: EngineState = .stopped
    var activeTasks: [DownloadTask] = []
    var waitingTasks: [DownloadTask] = []
    var stoppedTasks: [DownloadTask] = []
    var mediaTasks: [DownloadTask] = []
    var history: [HistoryRecord] = []
    var peers: [Peer] = []
    var peerCountries: [String: String] = [:]
    var globalStat = GlobalStat()
    var speedSamples: [SpeedSample] = []
    var extensionAPIPort: Int?
    var remoteAPIPort: Int?
    var trackerCount = 0
    var portMappingState: PortMappingState = .disabled
    var availablePlugins: [PluginDescriptor] = []
    var pluginCatalog: [PluginCatalogItem] = []
    var pluginStatus = ""
    var availableUpdate: AvailableUpdate?
    var updateStatus = "Not checked"
    var pendingAddURLs: [String] = []
    var metadataByGID: [String: TaskMetadata] = [:]
    var pendingCompletionAction: AppSettings.CompletionAction?
    var completionCountdown = 0
    var lastError: String?
    var isBusy = false

    let settingsStore: SettingsStore

    private let engine = Aria2Engine()
    private let historyStore: HistoryStore?
    private let notificationService = NotificationService()
    private let powerService = PowerAssertionService()
    private let extensionServer = ExtensionServer()
    private let remoteControlServer = RemoteControlServer()
    private let trackerService = TrackerService()
    private let diagnosticsService = DiagnosticsService()
    private let taskMetadataStore = TaskMetadataStore()
    private let clipboardMonitor = ClipboardMonitor()
    private let postProcessingService = PostProcessingService()
    private let mediaDownloadService = MediaDownloadService()
    private let rssService = RSSService()
    private let automationStateStore = AutomationStateStore()
    private let portMappingService = PortMappingService()
    private let geoIPService = GeoIPService()
    private let pluginService = PluginService()
    private let updateService = UpdateService()
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "downloads")
    private var client: Aria2RPCClient?
    private var pollingTask: Task<Void, Never>?
    private var recordedTerminalGIDs = Set<String>()
    private var didCompleteInitialRefresh = false
    private var appliedScheduledLimits: (String, String)?
    private var schedulePausedGIDs = Set<String>()
    private var automaticRetryGIDs = Set<String>()
    private var completionTask: Task<Void, Never>?
    private var hadOutstandingTransfers = false
    private var mediaOperations: [String: Task<Void, Never>] = [:]
    private var mediaSessionOptions: [String: [String: JSONValue]] = [:]
    private var automationTask: Task<Void, Never>?
    private var lastRSSCheck = Date.distantPast

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        historyStore = try? HistoryStore()
    }

    var allTasks: [DownloadTask] {
        activeTasks + waitingTasks + stoppedTasks + mediaTasks
    }

    var displayedActiveTasks: [DownloadTask] {
        activeTasks + mediaTasks.filter { $0.status == .active }
    }

    var visibleTasks: [DownloadTask] {
        let base: [DownloadTask]
        switch section {
        case .dashboard, .all: base = allTasks
        case .downloading: base = displayedActiveTasks
        case .waiting: base = waitingTasks.filter { $0.status == .waiting || $0.status == .paused }
            + mediaTasks.filter { $0.status == .waiting || $0.status == .paused }
        case .completed: base = stoppedTasks.filter { $0.status == .complete } + mediaTasks.filter { $0.status == .complete }
        case .failed: base = stoppedTasks.filter { $0.status == .error } + mediaTasks.filter { $0.status == .error }
        case .history: base = []
        }
        guard !searchText.isEmpty else { return base }
        return base.filter { task in
            task.name.localizedStandardContains(searchText)
                || task.gid.localizedStandardContains(searchText)
                || (metadataByGID[task.gid]?.label.localizedStandardContains(searchText) == true)
                || task.files.contains { $0.path.localizedStandardContains(searchText) }
        }
    }

    func label(for task: DownloadTask) -> String {
        metadataByGID[task.gid]?.label ?? ""
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

    var canRetrySelection: Bool {
        selectedTasks.contains { $0.status == .error || $0.status == .removed }
    }

    func start() async {
        guard client == nil else { return }
        engineState = .starting
        Task { [notificationService, settingsStore] in
            await notificationService.requestAuthorizationIfNeeded(enabled: settingsStore.values.notificationsEnabled)
        }
        await loadHistory()
        await loadTaskMetadata()
        await reloadPlugins()
        if settingsStore.values.features.updates.automaticallyChecks {
            Task { await self.checkForUpdates() }
        }
        configureClipboardMonitor()

        do {
            let started = try await engine.start(settings: settingsStore.runtimeValues)
            client = started.client
            engineState = .running(version: started.version)
            await configureExtensionServer(client: started.client, engineVersion: started.version)
            Task { await self.synchronizeTrackers(client: started.client) }
            Task { await self.configurePortMappings() }
            lastError = nil
            await refresh()
            beginPolling()
            beginAutomationPolling()
        } catch {
            engineState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
        completionTask?.cancel()
        completionTask = nil
        clipboardMonitor.stop()
        mediaOperations.values.forEach { $0.cancel() }
        mediaOperations.removeAll()
        automationTask?.cancel()
        automationTask = nil
        await engine.stop(client: client)
        await extensionServer.stop()
        await remoteControlServer.stop()
        await portMappingService.removeMappings()
        portMappingState = .disabled
        extensionAPIPort = nil
        remoteAPIPort = nil
        client = nil
        engineState = .stopped
        await powerService.update(activeDownloads: 0, enabled: false)
    }

    func restartEngine() async {
        isBusy = true
        pollingTask?.cancel()
        settingsStore.save()
        do {
            let restarted = try await engine.restart(settings: settingsStore.runtimeValues, client: client)
            client = restarted.client
            engineState = .running(version: restarted.version)
            await configureExtensionServer(client: restarted.client, engineVersion: restarted.version)
            Task { await self.synchronizeTrackers(client: restarted.client) }
            Task { await self.configurePortMappings() }
            configureClipboardMonitor()
            beginAutomationPolling()
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
            await ensureTaskMetadata(values.0 + values.1 + values.2)
            appendSpeedSample(stat: values.3)
            trimInvalidSelection()
            await persistNewTerminalTasks(values.2)
            if didCompleteInitialRefresh {
                await processNewCompletions(values.2)
            }
            await updateSystemState()
            await applySpeedScheduleIfNeeded()
            await applyTaskScheduleIfNeeded()
            await processAutomaticRetries(values.2)
            updateCompletionActionState()
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
            var expandedURLs: [String] = []
            for rawURL in rawURLs {
                expandedURLs.append(contentsOf: await pluginService.resolve(
                    rawURL,
                    enabled: settingsStore.values.features.plugins.enabled
                ))
            }
            for rawURL in expandedURLs {
                guard let url = DownloadURLNormalizer.normalize(rawURL) else { continue }
                var routedOptions = options
                routedOptions.directory = categorizedDirectory(for: url, options: options)
                if settingsStore.values.features.media.resolveStreamingManifests,
                   isMediaManifestURL(url) {
                    try await addMediaManifest(url, options: routedOptions)
                    continue
                }
                guard !shouldSkipExistingFile(source: url, options: routedOptions) else { continue }
                var aria2Options = try preparedAria2Options(for: routedOptions, source: url)
                if aria2Options["user-agent"] == nil {
                    aria2Options["user-agent"] = .string(settingsStore.values.userAgent)
                }
                let position = routedOptions.priority == .high ? 0 : nil
                let gid = try await client.addURI(url, options: aria2Options, position: position)
                let metadata = TaskMetadata(
                    gid: gid,
                    sourceURLs: [url],
                    sourceFilePath: nil,
                    options: redactedRetryOptions(aria2Options),
                    credentialProfileID: resolvedCredentialProfile(for: routedOptions, source: url)?.id,
                    label: routedOptions.label,
                    priority: routedOptions.priority,
                    scheduled: routedOptions.scheduled,
                    retryCount: 0,
                    nextRetryAt: nil,
                    createdAt: .now
                )
                try await taskMetadataStore.upsert(metadata)
                metadataByGID[gid] = metadata
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
            let position = taskOptions.priority == .high ? 0 : nil
            let gid = try await client.addTorrent(data: data, options: taskOptions.aria2Options, position: position)
            let archivedSource = try await taskMetadataStore.archiveTorrent(data: data, gid: gid)
            let metadata = TaskMetadata(
                gid: gid,
                sourceURLs: [],
                sourceFilePath: archivedSource.path,
                options: taskOptions.aria2Options,
                credentialProfileID: taskOptions.credentialProfileID,
                label: taskOptions.label,
                priority: taskOptions.priority,
                scheduled: taskOptions.scheduled,
                retryCount: 0,
                nextRetryAt: nil,
                createdAt: .now
            )
            try await taskMetadataStore.upsert(metadata)
            metadataByGID[gid] = metadata
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
        if url.isFileURL, ["metalink", "meta4"].contains(url.pathExtension.lowercased()) {
            await addMetalink(at: url)
            return
        }
        var options = AddTaskOptions(directory: settingsStore.values.downloadDirectory)
        options.userAgent = settingsStore.values.userAgent
        await addURLs([url.absoluteString], options: options)
    }

    func addMetalink(at url: URL, options: AddTaskOptions? = nil) async {
        guard let client else { return }
        isBusy = true
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let taskOptions = options ?? AddTaskOptions(directory: settingsStore.values.downloadDirectory)
            let gids = try await client.addMetalink(data: data, options: taskOptions.aria2Options)
            for gid in gids {
                let metadata = TaskMetadata(
                    gid: gid,
                    sourceURLs: [],
                    sourceFilePath: url.path,
                    options: taskOptions.aria2Options,
                    credentialProfileID: taskOptions.credentialProfileID,
                    label: taskOptions.label,
                    priority: taskOptions.priority,
                    scheduled: taskOptions.scheduled,
                    retryCount: 0,
                    nextRetryAt: nil,
                    createdAt: .now
                )
                try await taskMetadataStore.upsert(metadata)
                metadataByGID[gid] = metadata
            }
            showingAddTask = false
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    func pauseSelection() async {
        for task in selectedTasks where isMediaTask(task.gid) && task.status == .active {
            mediaOperations[task.gid]?.cancel()
            updateMediaTask(gid: task.gid, status: .paused)
            await updateMediaMetadata(gid: task.gid, status: .paused)
        }
        await runSelected { client, task in
            guard !self.isMediaTask(task.gid) else { return }
            guard task.status == .active || task.status == .waiting || task.status == .sharing else { return }
            try await client.pause(gid: task.gid)
        }
    }

    func resumeSelection() async {
        for task in selectedTasks where isMediaTask(task.gid) && (task.status == .paused || task.status == .error) {
            startMediaDownload(gid: task.gid)
        }
        await runSelected { client, task in
            guard !self.isMediaTask(task.gid) else { return }
            guard task.status == .paused else { return }
            try await client.resume(gid: task.gid)
        }
    }

    func togglePauseSelection() async {
        if canPauseSelection { await pauseSelection() }
        else if canResumeSelection { await resumeSelection() }
    }

    func removeSelection(deleteFiles: Bool = false) async {
        let tasks = selectedTasks
        let media = tasks.filter { isMediaTask($0.gid) }
        for task in media {
            mediaOperations[task.gid]?.cancel()
            mediaOperations.removeValue(forKey: task.gid)
            mediaTasks.removeAll { $0.gid == task.gid }
        }
        await runSelected { client, task in
            guard !self.isMediaTask(task.gid) else { return }
            if task.status.isTerminal {
                try await client.removeResult(gid: task.gid)
            } else {
                try await client.remove(gid: task.gid, force: task.status == .active)
            }
        }
        if deleteFiles {
            for task in tasks { moveTaskFilesToTrash(task) }
        }
        for task in tasks {
            try? await taskMetadataStore.remove(gid: task.gid)
            metadataByGID.removeValue(forKey: task.gid)
        }
        selectedTaskIDs.removeAll()
    }

    func confirmRemoval(of task: DownloadTask, deleteFiles: Bool) async {
        let alert = NSAlert()
        alert.alertStyle = deleteFiles ? .warning : .informational
        alert.messageText = deleteFiles ? "Move downloaded files to Trash?" : "Remove this download?"
        alert.informativeText = deleteFiles
            ? "\(task.name) will be removed from Kite and its downloaded files will be moved to the Trash."
            : "The task will be removed. Files already on disk will be kept."
        alert.addButton(withTitle: deleteFiles ? "Move to Trash" : "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectedTaskIDs = [task.gid]
        await removeSelection(deleteFiles: deleteFiles)
    }

    func retrySelection() async {
        for task in selectedTasks where isMediaTask(task.gid) && task.status == .error {
            startMediaDownload(gid: task.gid)
        }
        guard let client else { return }
        let tasks = selectedTasks.filter { !isMediaTask($0.gid) && ($0.status == .error || $0.status == .removed) }
        guard !tasks.isEmpty else { return }
        isBusy = true
        for task in tasks {
            do {
                let newGID = try await retry(task: task, client: client)
                selectedTaskIDs.remove(task.gid)
                selectedTaskIDs.insert(newGID)
            } catch {
                lastError = error.localizedDescription
            }
        }
        await refresh()
        isBusy = false
    }

    enum QueueMove: Sendable {
        case top
        case up
        case down
        case bottom
    }

    func moveSelection(_ move: QueueMove) async {
        guard let client else { return }
        let tasks = selectedTasks.filter { $0.status == .waiting || $0.status == .paused }
        guard !tasks.isEmpty else { return }
        isBusy = true
        do {
            for task in tasks {
                switch move {
                case .top:
                    _ = try await client.changePosition(gid: task.gid, position: 0)
                case .up:
                    _ = try await client.changePosition(gid: task.gid, position: -1, how: "POS_CUR")
                case .down:
                    _ = try await client.changePosition(gid: task.gid, position: 1, how: "POS_CUR")
                case .bottom:
                    _ = try await client.changePosition(gid: task.gid, position: waitingTasks.count + 1)
                }
            }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    func setPriority(_ priority: TaskPriority, task: DownloadTask) async {
        guard var metadata = metadataByGID[task.gid] else { return }
        metadata.priority = priority
        do {
            try await taskMetadataStore.upsert(metadata)
            metadataByGID[task.gid] = metadata
            selectedTaskIDs = [task.gid]
            if priority == .high { await moveSelection(.top) }
            if priority == .low { await moveSelection(.bottom) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeHistorySelection() async {
        guard let historyStore else { return }
        for id in selectedHistoryIDs {
            try? await historyStore.remove(id: id)
        }
        selectedHistoryIDs.removeAll()
        await loadHistory()
    }

    func retryHistory(_ record: HistoryRecord) async {
        var options = AddTaskOptions(directory: record.directory)
        if case let .string(filename)? = record.retryOptions["out"] { options.filename = filename }
        if case let .string(referer)? = record.retryOptions["referer"] { options.referer = referer }
        options.label = record.label
        if let sourceFilePath = record.sourceFilePath, !sourceFilePath.isEmpty {
            let url = URL(fileURLWithPath: sourceFilePath)
            if url.pathExtension.lowercased() == "torrent" { await addTorrent(at: url, options: options) }
            else { await addMetalink(at: url, options: options) }
        } else if let sourceURL = record.sourceURL {
            await addURLs([sourceURL], options: options)
        }
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
        clipboardMonitor.suppressCurrentContents()
    }

    func presentLinks(_ urls: [String]) {
        let normalized = urls.compactMap(DownloadURLNormalizer.normalize)
        guard !normalized.isEmpty else { return }
        pendingAddURLs = normalized
        showingAddTask = true
    }

    func pasteLinksFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        presentLinks(DownloadURLNormalizer.extractMany(from: value))
        clipboardMonitor.suppressCurrentContents()
    }

    func acceptDroppedURLs(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        let remoteURLs = urls.filter { !$0.isFileURL }.map(\.absoluteString)
        if !remoteURLs.isEmpty { presentLinks(remoteURLs) }
        for url in fileURLs {
            Task {
                switch url.pathExtension.lowercased() {
                case "torrent": await addTorrent(at: url)
                case "metalink", "meta4": await addMetalink(at: url)
                default: presentLinks([url.absoluteString])
                }
            }
        }
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

    func reloadPlugins() async {
        availablePlugins = await pluginService.discover()
    }

    func openPluginsDirectory() async {
        do {
            NSWorkspace.shared.open(try await pluginService.pluginsDirectory())
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshPluginCatalog() async {
        pluginStatus = "Loading catalog…"
        do {
            pluginCatalog = try await pluginService.fetchCatalog(from: settingsStore.values.features.plugins.registryURL)
            pluginStatus = "\(pluginCatalog.count) plugins available"
        } catch {
            pluginStatus = "Catalog unavailable"
            lastError = error.localizedDescription
        }
    }

    func installPlugin(_ item: PluginCatalogItem) async {
        pluginStatus = "Installing \(item.name)…"
        do {
            try await pluginService.install(item)
            await reloadPlugins()
            pluginStatus = "Installed \(item.name) \(item.version)"
        } catch {
            pluginStatus = "Installation failed"
            lastError = error.localizedDescription
        }
    }

    func checkForUpdates() async {
        updateStatus = "Checking…"
        do {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
            availableUpdate = try await updateService.check(
                feedURL: settingsStore.values.features.updates.feedURL,
                currentVersion: current
            )
            updateStatus = availableUpdate.map { "Version \($0.version) is available" } ?? "Kite is up to date"
            settingsStore.values.features.updates.lastCheckedAt = .now
            settingsStore.save()
        } catch {
            updateStatus = "Update check failed"
            lastError = error.localizedDescription
        }
    }

    func downloadAvailableUpdate() async {
        guard let availableUpdate else { return }
        updateStatus = "Downloading and verifying…"
        do {
            let url = try await updateService.download(availableUpdate)
            updateStatus = "Verified \(url.lastPathComponent)"
            NSWorkspace.shared.open(url)
        } catch {
            updateStatus = "Update download failed"
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
        case .downloading: displayedActiveTasks.count
        case .waiting: waitingTasks.count + mediaTasks.count { $0.status == .waiting || $0.status == .paused }
        case .completed: stoppedTasks.count { $0.status == .complete } + mediaTasks.count { $0.status == .complete }
        case .failed: stoppedTasks.count { $0.status == .error } + mediaTasks.count { $0.status == .error }
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

    private func beginAutomationPolling() {
        automationTask?.cancel()
        automationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.scanWatchDirectory()
                await self?.refreshRSSIfNeeded()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func scanWatchDirectory() async {
        let path = settingsStore.values.features.torrentAutomation.watchDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard ["torrent", "metalink", "meta4"].contains(file.pathExtension.lowercased()),
                  (try? await automationStateStore.claimWatchedFile(file)) == true else { continue }
            if file.pathExtension.lowercased() == "torrent" { await addTorrent(at: file) }
            else { await addMetalink(at: file) }
        }
    }

    private func refreshRSSIfNeeded(date: Date = .now) async {
        let automation = settingsStore.values.features.torrentAutomation
        let interval = TimeInterval(max(automation.rssCheckIntervalMinutes, 1) * 60)
        guard date.timeIntervalSince(lastRSSCheck) >= interval else { return }
        lastRSSCheck = date
        for feed in automation.feeds where feed.enabled {
            do {
                let items = try await rssService.fetch(feed)
                let rules = automation.rules.filter { $0.enabled && ($0.feedID == nil || $0.feedID == feed.id) }
                for item in items {
                    guard let rule = rules.first(where: { rssRule($0, matches: item) }),
                          (try? await automationStateStore.claimRSSURL(item.url)) == true else { continue }
                    var options = AddTaskOptions(
                        directory: rule.destination.isEmpty ? settingsStore.values.downloadDirectory : rule.destination
                    )
                    options.label = rule.label
                    options.paused = rule.paused
                    await addURLs([item.url], options: options)
                }
                if let index = settingsStore.values.features.torrentAutomation.feeds.firstIndex(where: { $0.id == feed.id }) {
                    settingsStore.values.features.torrentAutomation.feeds[index].lastCheckedAt = date
                }
            } catch {
                logger.warning("RSS feed \(feed.name) failed: \(error.localizedDescription)")
            }
        }
        settingsStore.save()
    }

    private func rssRule(_ rule: AppSettings.RSSRule, matches item: RSSItem) -> Bool {
        let pattern = rule.titlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return true }
        if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(item.title.startIndex ..< item.title.endIndex, in: item.title)
            return expression.firstMatch(in: item.title, range: range) != nil
        }
        return item.title.localizedCaseInsensitiveContains(pattern)
    }

    private func runSelected(_ operation: (Aria2RPCClient, DownloadTask) async throws -> Void) async {
        let ariaTasks = selectedTasks.filter { !isMediaTask($0.gid) }
        guard !ariaTasks.isEmpty, let client else { return }
        isBusy = true
        do {
            for task in ariaTasks { try await operation(client, task) }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
    }

    private func refreshPeers() async {
        guard let client, let task = selectedTask, task.isBitTorrent else { return }
        peers = (try? await client.peers(gid: task.gid)) ?? []
        do {
            try await geoIPService.configure(source: settingsStore.values.features.networkPolicy.geoIPDatabaseURL)
            var countries: [String: String] = [:]
            for peer in peers { countries[peer.id] = await geoIPService.country(for: peer.ip) }
            peerCountries = countries
        } catch {
            peerCountries = [:]
            logger.warning("GeoIP database failed: \(error.localizedDescription)")
        }
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
            try? await historyStore.upsert(task: task, metadata: metadataByGID[task.gid])
            recordedTerminalGIDs.insert(task.gid)
        }
        await loadHistory()
    }

    private func processNewCompletions(_ tasks: [DownloadTask]) async {
        let settings = settingsStore.values.features.postProcessing
        let hasActions = settings.autoExtractArchives || settings.revealCompletedFiles
            || settings.openCompletedFiles || !settings.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasActions else { return }
        for task in tasks where task.status == .complete {
            guard var metadata = metadataByGID[task.gid], metadata.postProcessedAt == nil else { continue }
            do {
                let result = try await postProcessingService.process(task: task, settings: settings)
                metadata.postProcessedAt = .now
                try await taskMetadataStore.upsert(metadata)
                metadataByGID[task.gid] = metadata
                if settings.revealCompletedFiles {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                if settings.openCompletedFiles { NSWorkspace.shared.open(result.outputURL) }
            } catch {
                lastError = "Post-processing \(task.name) failed: \(error.localizedDescription)"
            }
        }
    }

    private func loadHistory() async {
        guard let historyStore else { return }
        history = (try? await historyStore.records()) ?? []
        recordedTerminalGIDs.formUnion(history.map(\.id))
    }

    private func updateSystemState() async {
        await powerService.update(
            activeDownloads: displayedActiveTasks.count,
            enabled: settingsStore.values.preventSleepWhileDownloading
        )
        if settingsStore.values.showDockBadge {
            NSApp.dockTile.badgeLabel = displayedActiveTasks.isEmpty ? nil : String(displayedActiveTasks.count)
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

    private func applyTaskScheduleIfNeeded(date: Date = .now) async {
        guard let client else { return }
        let schedule = settingsStore.values.features.taskSchedule
        guard schedule.enabled, schedule.pauseOutsideWindow else {
            for gid in schedulePausedGIDs { try? await client.resume(gid: gid) }
            schedulePausedGIDs.removeAll()
            return
        }
        let isInside = isInsideSchedule(
            startHour: schedule.startHour,
            endHour: schedule.endHour,
            weekdays: schedule.weekdays,
            date: date
        )
        do {
            if isInside {
                for gid in schedulePausedGIDs {
                    try? await client.resume(gid: gid)
                }
                schedulePausedGIDs.removeAll()
            } else {
                let scheduledTasks = (activeTasks + waitingTasks).filter { metadataByGID[$0.gid]?.scheduled == true }
                for task in scheduledTasks where task.status == .active || task.status == .waiting {
                    try await client.pause(gid: task.gid)
                    schedulePausedGIDs.insert(task.gid)
                }
            }
        } catch {
            logger.warning("Could not apply task schedule: \(error.localizedDescription)")
        }
    }

    private func isInsideSchedule(startHour: Int, endHour: Int, weekdays: Set<Int>, date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        guard weekdays.contains(isoWeekday) else { return false }
        let hour = Calendar.current.component(.hour, from: date)
        if endHour >= 24 { return hour >= startHour }
        if startHour <= endHour { return (startHour ..< endHour).contains(hour) }
        return hour >= startHour || hour < endHour
    }

    private func processAutomaticRetries(_ stopped: [DownloadTask], date: Date = .now) async {
        let policy = settingsStore.values.features.reliability
        guard policy.automaticRetry, policy.maxTries > 0, let client else { return }
        for task in stopped where task.status == .error && !automaticRetryGIDs.contains(task.gid) {
            guard var metadata = metadataByGID[task.gid], metadata.retryCount < policy.maxTries else { continue }
            if metadata.nextRetryAt == nil {
                let delay = max(policy.retryWaitSeconds, 1) * Int(pow(2.0, Double(metadata.retryCount)))
                metadata.nextRetryAt = date.addingTimeInterval(TimeInterval(min(delay, 300)))
                try? await taskMetadataStore.upsert(metadata)
                metadataByGID[task.gid] = metadata
                continue
            }
            guard let nextRetryAt = metadata.nextRetryAt, nextRetryAt <= date else { continue }
            automaticRetryGIDs.insert(task.gid)
            do {
                _ = try await retry(task: task, client: client)
            } catch {
                metadata.retryCount += 1
                metadata.nextRetryAt = date.addingTimeInterval(TimeInterval(max(policy.retryWaitSeconds, 1)))
                try? await taskMetadataStore.upsert(metadata)
                metadataByGID[task.gid] = metadata
                logger.warning("Automatic retry failed for \(task.gid): \(error.localizedDescription)")
            }
            automaticRetryGIDs.remove(task.gid)
        }
    }

    private func retry(task: DownloadTask, client: Aria2RPCClient) async throws -> String {
        var metadata = metadataByGID[task.gid] ?? TaskMetadata(
            gid: task.gid,
            sourceURLs: task.files.flatMap(\.uris).map(\.uri),
            sourceFilePath: nil,
            options: ["dir": .string(task.directory)],
            credentialProfileID: nil,
            label: "",
            priority: .normal,
            scheduled: false,
            retryCount: 0,
            nextRetryAt: nil,
            createdAt: .now
        )
        try await taskMetadataStore.upsert(metadata)

        var options = metadata.options
        if let profileID = metadata.credentialProfileID,
           let profile = settingsStore.values.features.credentialProfiles.first(where: { $0.id == profileID }),
           let secret = try KeychainService.credential(id: profileID) {
            applyCredential(profile: profile, secret: secret, options: &options)
        }

        let position = metadata.priority == .high ? 0 : nil
        let newGID: String
        if let path = metadata.sourceFilePath {
            let sourceURL = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: sourceURL)
            if sourceURL.pathExtension.lowercased() == "torrent" {
                newGID = try await client.addTorrent(data: data, options: options, position: position)
            } else {
                guard let first = try await client.addMetalink(data: data, options: options, position: position).first else {
                    throw Aria2RPCError(code: -1, message: "Metalink retry created no task")
                }
                newGID = first
            }
        } else {
            let source = metadata.sourceURLs.first
                ?? task.files.flatMap(\.uris).first?.uri
                ?? task.infoHash.map { "magnet:?xt=urn:btih:\($0)" }
            guard let source else { throw Aria2RPCError(code: -1, message: "The original source is unavailable") }
            newGID = try await client.addURI(source, options: options, position: position)
        }

        try? await client.removeResult(gid: task.gid)
        metadata.retryCount += 1
        try await taskMetadataStore.replaceGID(task.gid, with: newGID, retryCount: metadata.retryCount)
        metadataByGID.removeValue(forKey: task.gid)
        if let updated = await taskMetadataStore.metadata(for: newGID) {
            metadataByGID[newGID] = updated
        } else {
            metadata.gid = newGID
            metadata.nextRetryAt = nil
            metadataByGID[newGID] = metadata
        }
        return newGID
    }

    private func updateCompletionActionState() {
        let outstanding = !displayedActiveTasks.isEmpty || waitingTasks.contains { !$0.status.isTerminal }
        defer { hadOutstandingTransfers = outstanding }
        guard hadOutstandingTransfers, !outstanding, pendingCompletionAction == nil else { return }
        let action = settingsStore.values.features.taskSchedule.completionAction
        guard action != .none else { return }
        startCompletionCountdown(action)
    }

    private func startCompletionCountdown(_ action: AppSettings.CompletionAction) {
        completionTask?.cancel()
        pendingCompletionAction = action
        completionCountdown = max(settingsStore.values.features.taskSchedule.completionCountdownSeconds, 0)
        completionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.completionCountdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.completionCountdown -= 1
            }
            guard !Task.isCancelled else { return }
            do {
                try CompletionActionService.perform(action)
            } catch {
                self.lastError = error.localizedDescription
            }
            self.pendingCompletionAction = nil
        }
    }

    func cancelCompletionAction() {
        completionTask?.cancel()
        completionTask = nil
        pendingCompletionAction = nil
        completionCountdown = 0
    }

    private func configureClipboardMonitor() {
        clipboardMonitor.stop()
        guard settingsStore.values.features.capture.monitorClipboard else { return }
        clipboardMonitor.start { [weak self] urls in
            guard let self else { return }
            let ignoredHosts = Set(self.settingsStore.values.features.capture.ignoredHosts.map { $0.lowercased() })
            let accepted = urls.filter { value in
                guard let host = URL(string: value)?.host?.lowercased() else { return true }
                return !ignoredHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
            }
            guard !accepted.isEmpty else { return }
            if self.settingsStore.values.features.capture.confirmClipboardLinks {
                self.presentLinks(accepted)
            } else {
                var options = AddTaskOptions(directory: self.settingsStore.values.downloadDirectory)
                options.userAgent = self.settingsStore.values.userAgent
                Task { await self.addURLs(accepted, options: options) }
            }
        }
    }

    private func loadTaskMetadata() async {
        let allMetadata = await taskMetadataStore.all()
        metadataByGID = Dictionary(uniqueKeysWithValues: allMetadata.map { ($0.gid, $0) })
        mediaTasks = allMetadata.compactMap { metadata in
            guard metadata.transport == .media, let source = metadata.sourceURLs.first else { return nil }
            let status: DownloadStatus = metadata.localStatus == .active ? .paused : (metadata.localStatus ?? .paused)
            let output = metadata.localOutputPath ?? mediaOutputPath(source: source, options: metadata.options)
            return DownloadTask.media(
                gid: metadata.gid,
                status: status,
                sourceURL: source,
                outputPath: output,
                completedLength: metadata.localCompletedLength ?? 0,
                totalLength: metadata.localTotalLength ?? 0
            )
        }
    }

    private func ensureTaskMetadata(_ tasks: [DownloadTask]) async {
        for task in tasks where metadataByGID[task.gid] == nil {
            let sourceURLs = task.files.flatMap(\.uris).map(\.uri)
            guard !sourceURLs.isEmpty || task.infoHash != nil else { continue }
            let metadata = TaskMetadata(
                gid: task.gid,
                sourceURLs: sourceURLs.isEmpty ? task.infoHash.map { ["magnet:?xt=urn:btih:\($0)"] } ?? [] : sourceURLs,
                sourceFilePath: nil,
                options: ["dir": .string(task.directory)],
                credentialProfileID: nil,
                label: "",
                priority: .normal,
                scheduled: false,
                retryCount: 0,
                nextRetryAt: nil,
                createdAt: .now
            )
            try? await taskMetadataStore.upsert(metadata)
            metadataByGID[task.gid] = metadata
        }
    }

    private func preparedAria2Options(for taskOptions: AddTaskOptions, source: String) throws -> [String: JSONValue] {
        var options = taskOptions.aria2Options
        if taskOptions.scheduled { options["pause"] = .string("true") }
        if let profile = resolvedCredentialProfile(for: taskOptions, source: source),
           let secret = try KeychainService.credential(id: profile.id) {
            applyCredential(profile: profile, secret: secret, options: &options)
        }
        return options
    }

    private func resolvedCredentialProfile(for options: AddTaskOptions, source: String) -> AppSettings.CredentialProfile? {
        let profiles = settingsStore.values.features.credentialProfiles
        if let id = options.credentialProfileID { return profiles.first { $0.id == id } }
        guard let host = URL(string: source)?.host?.lowercased() else { return nil }
        return profiles.first { profile in
            let pattern = profile.hostPattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !pattern.isEmpty && (host == pattern || host.hasSuffix(".\(pattern)"))
        }
    }

    private func applyCredential(
        profile: AppSettings.CredentialProfile,
        secret: CredentialSecret,
        options: inout [String: JSONValue]
    ) {
        if profile.sendsCookie {
            guard !secret.cookie.isEmpty else { return }
            var headers = options["header"]?.arrayValue ?? []
            headers.removeAll { $0.stringValue?.lowercased().hasPrefix("cookie:") == true }
            headers.append(.string("Cookie: \(secret.cookie)"))
            options["header"] = .array(headers)
        } else {
            options["http-user"] = .string(profile.username)
            options["http-passwd"] = .string(secret.password)
            options["ftp-user"] = .string(profile.username)
            options["ftp-passwd"] = .string(secret.password)
        }
    }

    private func redactedRetryOptions(_ options: [String: JSONValue]) -> [String: JSONValue] {
        options.filter { key, _ in
            !["header", "http-passwd", "ftp-passwd", "all-proxy-passwd"].contains(key)
        }
    }

    private func shouldSkipExistingFile(source: String, options: AddTaskOptions) -> Bool {
        guard settingsStore.values.features.reliability.conflictPolicy == .skip else { return false }
        let name = options.filename.isEmpty
            ? URL(string: source)?.lastPathComponent.removingPercentEncoding ?? ""
            : options.filename
        guard !name.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: options.directory).appending(path: name).path)
    }

    private func moveTaskFilesToTrash(_ task: DownloadTask) {
        var seen = Set<String>()
        for file in task.files where !file.path.isEmpty && seen.insert(file.path).inserted {
            let url = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var resultingURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                lastError = "Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)"
            }
        }
    }

    private func configureExtensionServer(client: Aria2RPCClient, engineVersion: String) async {
        if !settingsStore.values.extensionServerEnabled {
            await extensionServer.stop()
            extensionAPIPort = nil
        } else {
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

        let remote = settingsStore.values.features.remote
        if !remote.enabled {
            await remoteControlServer.stop()
            remoteAPIPort = nil
        } else {
            do {
                remoteAPIPort = try await remoteControlServer.start(
                    preferredPort: remote.port,
                    allowLAN: remote.allowLAN,
                    settings: settingsStore.values,
                    client: client,
                    engineVersion: engineVersion
                )
            } catch {
                remoteAPIPort = nil
                logger.warning("Remote API could not start: \(error.localizedDescription)")
            }
        }
    }

    private func synchronizeTrackers(client: Aria2RPCClient) async {
        trackerCount = await trackerService.synchronize(sources: settingsStore.values.trackerURLs, client: client)
    }

    private func configurePortMappings() async {
        portMappingState = .mapping
        portMappingState = await portMappingService.mapPorts(settings: settingsStore.values)
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

    private func isMediaManifestURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    private func isMediaTask(_ gid: String) -> Bool {
        metadataByGID[gid]?.transport == .media
    }

    private func addMediaManifest(_ source: String, options: AddTaskOptions) async throws {
        guard let sourceURL = URL(string: source) else { throw MediaDownloadError.invalidManifest }
        let gid = "media-\(UUID().uuidString.lowercased())"
        let prepared = try preparedAria2Options(for: options, source: source)
        let outputPath = mediaOutputPath(source: source, options: prepared)
        var metadata = TaskMetadata(
            gid: gid,
            sourceURLs: [source],
            sourceFilePath: nil,
            options: redactedRetryOptions(prepared),
            credentialProfileID: resolvedCredentialProfile(for: options, source: source)?.id,
            label: options.label.isEmpty ? "Media" : options.label,
            priority: options.priority,
            scheduled: options.scheduled,
            retryCount: 0,
            nextRetryAt: nil,
            createdAt: .now
        )
        metadata.transport = .media
        metadata.localStatus = options.paused ? .paused : .active
        metadata.localOutputPath = outputPath
        try await taskMetadataStore.upsert(metadata)
        metadataByGID[gid] = metadata
        mediaSessionOptions[gid] = prepared
        mediaTasks.append(DownloadTask.media(
            gid: gid,
            status: options.paused ? .paused : .active,
            sourceURL: sourceURL.absoluteString,
            outputPath: outputPath
        ))
        if !options.paused { startMediaDownload(gid: gid) }
    }

    private func startMediaDownload(gid: String) {
        guard var metadata = metadataByGID[gid],
              metadata.transport == .media,
              let source = metadata.sourceURLs.first,
              let sourceURL = URL(string: source) else { return }
        mediaOperations[gid]?.cancel()
        metadata.localStatus = .active
        metadata.postProcessedAt = nil
        metadataByGID[gid] = metadata
        Task { try? await taskMetadataStore.upsert(metadata) }

        var options = mediaSessionOptions[gid] ?? metadata.options
        if let profileID = metadata.credentialProfileID,
           let profile = settingsStore.values.features.credentialProfiles.first(where: { $0.id == profileID }),
           let secret = try? KeychainService.credential(id: profileID) {
            applyCredential(profile: profile, secret: secret, options: &options)
        }
        let outputPath = metadata.localOutputPath ?? mediaOutputPath(source: source, options: options)
        updateMediaTask(gid: gid, status: .active, outputPath: outputPath, errorMessage: nil)
        let request = MediaDownloadRequest(
            sourceURL: sourceURL,
            destinationDirectory: URL(fileURLWithPath: options["dir"]?.stringValue ?? settingsStore.values.downloadDirectory),
            filename: options["out"]?.stringValue ?? "",
            preferredHeight: settingsStore.values.features.media.preferredHeight,
            headers: mediaHeaders(from: options)
        )
        let service = mediaDownloadService
        mediaOperations[gid] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let finalURL = try await service.download(request) { [weak self] progress in
                    Task { @MainActor in self?.updateMediaProgress(gid: gid, progress: progress) }
                }
                guard !Task.isCancelled else { return }
                self.updateMediaTask(
                    gid: gid,
                    status: .complete,
                    outputPath: finalURL.path,
                    completedLength: self.metadataByGID[gid]?.localCompletedLength ?? 0,
                    totalLength: self.metadataByGID[gid]?.localCompletedLength ?? 0,
                    downloadSpeed: 0,
                    errorMessage: nil
                )
                if var completedMetadata = self.metadataByGID[gid] {
                    completedMetadata.localStatus = .complete
                    completedMetadata.localOutputPath = finalURL.path
                    completedMetadata.localTotalLength = completedMetadata.localCompletedLength
                    try await self.taskMetadataStore.upsert(completedMetadata)
                    self.metadataByGID[gid] = completedMetadata
                }
                if let task = self.mediaTasks.first(where: { $0.gid == gid }) {
                    try? await self.historyStore?.upsert(task: task, metadata: self.metadataByGID[gid])
                    self.recordedTerminalGIDs.insert(gid)
                    await self.processNewCompletions([task])
                    await self.loadHistory()
                }
            } catch is CancellationError {
                if self.mediaTasks.contains(where: { $0.gid == gid }) {
                    self.updateMediaTask(gid: gid, status: .paused)
                    await self.updateMediaMetadata(gid: gid, status: .paused)
                }
            } catch {
                self.updateMediaTask(gid: gid, status: .error, downloadSpeed: 0, errorMessage: error.localizedDescription)
                await self.updateMediaMetadata(gid: gid, status: .error)
                self.lastError = "Media download failed: \(error.localizedDescription)"
            }
            self.mediaOperations.removeValue(forKey: gid)
        }
    }

    private func updateMediaProgress(gid: String, progress: MediaDownloadProgress) {
        let estimatedTotal = progress.fraction > 0
            ? Int64(Double(progress.downloadedBytes) / progress.fraction)
            : progress.downloadedBytes
        updateMediaTask(
            gid: gid,
            status: .active,
            completedLength: progress.downloadedBytes,
            totalLength: max(estimatedTotal, progress.downloadedBytes),
            downloadSpeed: progress.bytesPerSecond
        )
        if var metadata = metadataByGID[gid] {
            metadata.localCompletedLength = progress.downloadedBytes
            metadata.localTotalLength = max(estimatedTotal, progress.downloadedBytes)
            metadataByGID[gid] = metadata
        }
    }

    private func updateMediaTask(
        gid: String,
        status: DownloadStatus,
        outputPath: String? = nil,
        completedLength: Int64? = nil,
        totalLength: Int64? = nil,
        downloadSpeed: Int64? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = mediaTasks.firstIndex(where: { $0.gid == gid }),
              let source = metadataByGID[gid]?.sourceURLs.first else { return }
        let old = mediaTasks[index]
        mediaTasks[index] = DownloadTask.media(
            gid: gid,
            status: status,
            sourceURL: source,
            outputPath: outputPath ?? old.primaryFileURL?.path ?? metadataByGID[gid]?.localOutputPath ?? "",
            completedLength: completedLength ?? old.completedLength,
            totalLength: totalLength ?? old.totalLength,
            downloadSpeed: downloadSpeed ?? old.downloadSpeed,
            errorMessage: errorMessage
        )
    }

    private func updateMediaMetadata(gid: String, status: DownloadStatus) async {
        guard var metadata = metadataByGID[gid] else { return }
        metadata.localStatus = status
        if let task = mediaTasks.first(where: { $0.gid == gid }) {
            metadata.localCompletedLength = task.completedLength
            metadata.localTotalLength = task.totalLength
            metadata.localOutputPath = task.primaryFileURL?.path
        }
        try? await taskMetadataStore.upsert(metadata)
        metadataByGID[gid] = metadata
    }

    private func mediaOutputPath(source: String, options: [String: JSONValue]) -> String {
        let directory = options["dir"]?.stringValue ?? settingsStore.values.downloadDirectory
        let filename = options["out"]?.stringValue
            ?? URL(string: source)?.deletingPathExtension().lastPathComponent
            ?? "Media"
        let output = URL(fileURLWithPath: directory).appending(path: filename)
        return output.pathExtension.isEmpty ? output.appendingPathExtension("mp4").path : output.path
    }

    private func mediaHeaders(from options: [String: JSONValue]) -> [String: String] {
        var headers: [String: String] = [:]
        if let userAgent = options["user-agent"]?.stringValue { headers["User-Agent"] = userAgent }
        if let referer = options["referer"]?.stringValue { headers["Referer"] = referer }
        for value in options["header"]?.arrayValue ?? [] {
            guard let line = value.stringValue, let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}
