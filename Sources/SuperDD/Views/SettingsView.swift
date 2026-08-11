import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settingsStore: SettingsStore
    let downloadStore: DownloadStore
    @State private var showingResetConfirmation = false

    var body: some View {
        TabView {
            GeneralSettings(settingsStore: settingsStore)
                .tabItem { Label("General", systemImage: "gearshape") }
            DownloadSettings(settingsStore: settingsStore)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            AutomationSettings(settingsStore: settingsStore)
                .tabItem { Label("Automation", systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90") }
            AccountSettings(settingsStore: settingsStore)
                .tabItem { Label("Accounts", systemImage: "key") }
            BitTorrentSettings(settingsStore: settingsStore)
                .tabItem { Label("BitTorrent", systemImage: "point.3.connected.trianglepath.dotted") }
            NetworkSettings(settingsStore: settingsStore, downloadStore: downloadStore)
                .tabItem { Label("Network", systemImage: "network") }
            AdvancedSettings(settingsStore: settingsStore, downloadStore: downloadStore, showingResetConfirmation: $showingResetConfirmation)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .scenePadding()
        .symbolRenderingMode(.monochrome)
        .frame(width: 820, height: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let error = settingsStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("Engine settings take effect after restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save and Restart Engine") {
                    Task { await downloadStore.restartEngine() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadStore.isBusy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog(
            "Restore all settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) { settingsStore.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your download history and files are not removed.")
        }
    }
}

private struct AutomationSettings: View {
    @Bindable var settingsStore: SettingsStore
    @State private var searchQuery = ""

    var body: some View {
        Form {
            Section("Download Capture") {
                Toggle("Monitor clipboard for download links", isOn: $settingsStore.values.features.capture.monitorClipboard)
                Toggle("Confirm clipboard links before adding", isOn: $settingsStore.values.features.capture.confirmClipboardLinks)
                    .disabled(!settingsStore.values.features.capture.monitorClipboard)
                LabeledContent("Ignored hosts") {
                    TextField(
                        "example.com, internal.example",
                        text: Binding(
                            get: { settingsStore.values.features.capture.ignoredHosts.joined(separator: ", ") },
                            set: {
                                settingsStore.values.features.capture.ignoredHosts = $0
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                }
            }

            Section("Reliability") {
                Toggle("Automatically retry failed downloads", isOn: $settingsStore.values.features.reliability.automaticRetry)
                Stepper(
                    "Maximum attempts: \(settingsStore.values.features.reliability.maxTries)",
                    value: $settingsStore.values.features.reliability.maxTries,
                    in: 0 ... 100
                )
                Stepper(
                    "Initial retry delay: \(settingsStore.values.features.reliability.retryWaitSeconds) seconds",
                    value: $settingsStore.values.features.reliability.retryWaitSeconds,
                    in: 1 ... 300
                )
                Toggle("Verify pieces and checksums when available", isOn: $settingsStore.values.features.reliability.checkIntegrity)
                Picker("Existing files", selection: $settingsStore.values.features.reliability.conflictPolicy) {
                    ForEach(AppSettings.ConflictPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
            }

            Section("Task Schedule") {
                Toggle("Enable task schedule", isOn: $settingsStore.values.features.taskSchedule.enabled)
                Toggle("Pause scheduled tasks outside the window", isOn: $settingsStore.values.features.taskSchedule.pauseOutsideWindow)
                    .disabled(!settingsStore.values.features.taskSchedule.enabled)
                HStack {
                    Stepper(
                        "From \(settingsStore.values.features.taskSchedule.startHour):00",
                        value: $settingsStore.values.features.taskSchedule.startHour,
                        in: 0 ... 23
                    )
                    Stepper(
                        "to \(displayEndHour):00",
                        value: $settingsStore.values.features.taskSchedule.endHour,
                        in: 1 ... 24
                    )
                }
                HStack(spacing: 6) {
                    ForEach(Array(zip(["M", "T", "W", "T", "F", "S", "S"], 1 ... 7)), id: \.1) { label, weekday in
                        Toggle(label, isOn: taskWeekdayBinding(weekday))
                            .toggleStyle(.button)
                            .buttonBorderShape(.circle)
                            .controlSize(.small)
                    }
                }
                Picker("When all tasks finish", selection: $settingsStore.values.features.taskSchedule.completionAction) {
                    ForEach(AppSettings.CompletionAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Stepper(
                    "Action countdown: \(settingsStore.values.features.taskSchedule.completionCountdownSeconds) seconds",
                    value: $settingsStore.values.features.taskSchedule.completionCountdownSeconds,
                    in: 0 ... 300,
                    step: 5
                )
                .disabled(settingsStore.values.features.taskSchedule.completionAction == .none)
            }

            Section("After Download") {
                Toggle("Automatically extract supported archives", isOn: $settingsStore.values.features.postProcessing.autoExtractArchives)
                Toggle("Delete archive after successful extraction", isOn: $settingsStore.values.features.postProcessing.deleteArchiveAfterExtraction)
                    .disabled(!settingsStore.values.features.postProcessing.autoExtractArchives)
                TextField("Extraction subfolder (optional)", text: $settingsStore.values.features.postProcessing.extractionSubdirectory)
                Toggle("Reveal completed files in Finder", isOn: $settingsStore.values.features.postProcessing.revealCompletedFiles)
                Toggle("Open completed files", isOn: $settingsStore.values.features.postProcessing.openCompletedFiles)
                TextField("Run command after completion", text: $settingsStore.values.features.postProcessing.command)
                Text("Commands run only after explicit configuration. File paths are passed through environment variables, not shell interpolation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Streaming Media") {
                Toggle("Resolve HLS and DASH manifests", isOn: $settingsStore.values.features.media.resolveStreamingManifests)
                Picker("Preferred video height", selection: $settingsStore.values.features.media.preferredHeight) {
                    Text("480p").tag(480)
                    Text("720p").tag(720)
                    Text("1080p").tag(1_080)
                    Text("1440p").tag(1_440)
                    Text("2160p").tag(2_160)
                }
                .disabled(!settingsStore.values.features.media.resolveStreamingManifests)
                Text("Static HLS media playlists and DASH SegmentList manifests download as resumable native tasks. DRM and encrypted HLS are rejected with an explicit error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Watch Folder and RSS") {
                HStack {
                    TextField("Watch folder", text: $settingsStore.values.features.torrentAutomation.watchDirectory)
                    Button("Choose…") { chooseWatchDirectory() }
                }
                Stepper(
                    "RSS refresh: every \(settingsStore.values.features.torrentAutomation.rssCheckIntervalMinutes) minutes",
                    value: $settingsStore.values.features.torrentAutomation.rssCheckIntervalMinutes,
                    in: 1 ... 1_440
                )
                ForEach($settingsStore.values.features.torrentAutomation.feeds) { $feed in
                    HStack {
                        Toggle("", isOn: $feed.enabled).labelsHidden()
                        TextField("Feed name", text: $feed.name).frame(width: 150)
                        TextField("https://example.com/feed.xml", text: $feed.url)
                        Button(role: .destructive) {
                            settingsStore.values.features.torrentAutomation.feeds.removeAll { $0.id == feed.id }
                            settingsStore.values.features.torrentAutomation.rules.removeAll { $0.feedID == feed.id }
                        } label: {
                            Label("Remove Feed", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button("Add RSS Feed") {
                    settingsStore.values.features.torrentAutomation.feeds.append(.init(name: "New Feed", url: ""))
                }

                ForEach($settingsStore.values.features.torrentAutomation.rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden()
                            TextField("Rule name", text: $rule.name).frame(width: 150)
                            Picker("Feed", selection: $rule.feedID) {
                                Text("All feeds").tag(UUID?.none)
                                ForEach(settingsStore.values.features.torrentAutomation.feeds) { feed in
                                    Text(feed.name).tag(Optional(feed.id))
                                }
                            }
                            Button(role: .destructive) {
                                settingsStore.values.features.torrentAutomation.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Label("Remove Rule", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                        }
                        HStack {
                            TextField("Title regex (blank matches all)", text: $rule.titlePattern)
                            TextField("Destination", text: $rule.destination)
                            TextField("Label", text: $rule.label).frame(width: 100)
                            Toggle("Paused", isOn: $rule.paused)
                        }
                    }
                }
                Button("Add RSS Rule") {
                    settingsStore.values.features.torrentAutomation.rules.append(
                        .init(name: "New Rule", feedID: nil, titlePattern: "", destination: "")
                    )
                }
            }

            Section("Search Providers") {
                HStack {
                    TextField("Search torrents and downloads", text: $searchQuery)
                    Menu("Search") {
                        ForEach(settingsStore.values.features.torrentAutomation.searchProviders.filter(\.enabled)) { provider in
                            Button(provider.name) { openSearch(provider) }
                        }
                    }
                    .disabled(searchQuery.isEmpty)
                }
                ForEach($settingsStore.values.features.torrentAutomation.searchProviders) { $provider in
                    HStack {
                        Toggle("", isOn: $provider.enabled).labelsHidden()
                        TextField("Provider", text: $provider.name).frame(width: 130)
                        TextField("https://example.com/?q={query}", text: $provider.urlTemplate)
                        Button(role: .destructive) {
                            settingsStore.values.features.torrentAutomation.searchProviders.removeAll { $0.id == provider.id }
                        } label: {
                            Label("Remove Provider", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button("Add Search Provider") {
                    settingsStore.values.features.torrentAutomation.searchProviders.append(
                        .init(name: "New Provider", urlTemplate: "https://example.com/search?q={query}")
                    )
                }
                Text("Search templates open in your default browser. Use {query} where the percent-encoded search term belongs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var displayEndHour: Int { settingsStore.values.features.taskSchedule.endHour % 24 }

    private func taskWeekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settingsStore.values.features.taskSchedule.weekdays.contains(weekday) },
            set: { selected in
                if selected { settingsStore.values.features.taskSchedule.weekdays.insert(weekday) }
                else { settingsStore.values.features.taskSchedule.weekdays.remove(weekday) }
            }
        )
    }

    private func chooseWatchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.values.features.torrentAutomation.watchDirectory = url.path
        }
    }

    private func openSearch(_ provider: AppSettings.SearchProvider) {
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        guard let url = URL(string: provider.urlTemplate.replacingOccurrences(of: "{query}", with: encoded)) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AccountSettings: View {
    @Bindable var settingsStore: SettingsStore
    @State private var editingProfile: AppSettings.CredentialProfile?
    @State private var creatingProfile = false

    var body: some View {
        Form {
            Section("Website Credentials") {
                if settingsStore.values.features.credentialProfiles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Credentials",
                        systemImage: "key",
                        description: Text("Passwords and cookies are stored in your login Keychain.")
                    )
                } else {
                    ForEach(settingsStore.values.features.credentialProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.hostPattern)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(profile.sendsCookie ? "Cookie" : profile.username)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Edit") { editingProfile = profile }
                            Button("Delete", role: .destructive) { remove(profile) }
                        }
                    }
                }
                Button("Add Credential…") { creatingProfile = true }
            }

            Section("Storage") {
                Label("Secrets are stored with Security.framework in the macOS login Keychain.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("settings.json contains only the profile name, host rule, and username. Diagnostics never include Keychain values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $creatingProfile) {
            CredentialEditor(profile: nil) { profile, secret in save(profile, secret: secret) }
        }
        .sheet(item: $editingProfile) { profile in
            CredentialEditor(profile: profile) { updated, secret in save(updated, secret: secret) }
        }
    }

    private func save(_ profile: AppSettings.CredentialProfile, secret: CredentialSecret) {
        do {
            try KeychainService.saveCredential(secret, id: profile.id)
            if let index = settingsStore.values.features.credentialProfiles.firstIndex(where: { $0.id == profile.id }) {
                settingsStore.values.features.credentialProfiles[index] = profile
            } else {
                settingsStore.values.features.credentialProfiles.append(profile)
            }
            settingsStore.save()
        } catch {
            settingsStore.lastError = error.localizedDescription
        }
    }

    private func remove(_ profile: AppSettings.CredentialProfile) {
        do {
            try KeychainService.removeCredential(id: profile.id)
            settingsStore.values.features.credentialProfiles.removeAll { $0.id == profile.id }
            settingsStore.save()
        } catch {
            settingsStore.lastError = error.localizedDescription
        }
    }
}

private struct CredentialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: AppSettings.CredentialProfile
    @State private var password = ""
    @State private var cookie = ""
    let onSave: (AppSettings.CredentialProfile, CredentialSecret) -> Void

    init(
        profile: AppSettings.CredentialProfile?,
        onSave: @escaping (AppSettings.CredentialProfile, CredentialSecret) -> Void
    ) {
        let value = profile ?? .init(name: "", hostPattern: "", username: "")
        _profile = State(initialValue: value)
        if let profile, let secret = try? KeychainService.credential(id: profile.id) {
            _password = State(initialValue: secret.password)
            _cookie = State(initialValue: secret.cookie)
        }
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.name.isEmpty ? "New Credential" : "Edit Credential")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                TextField("Host", text: $profile.hostPattern, prompt: Text("example.com"))
                Toggle("Use browser/session cookie", isOn: $profile.sendsCookie)
                if profile.sendsCookie {
                    SecureField("Cookie header value", text: $cookie)
                } else {
                    TextField("Username", text: $profile.username)
                    SecureField("Password", text: $password)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(profile, CredentialSecret(password: password, cookie: cookie))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.isEmpty || profile.hostPattern.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settingsStore.values.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("System") {
                Toggle("Start at login", isOn: $settingsStore.values.startAtLogin)
                Toggle("Show active download count on Dock icon", isOn: $settingsStore.values.showDockBadge)
                Toggle("Prevent sleep while downloading", isOn: $settingsStore.values.preventSleepWhileDownloading)
                Toggle("Notify when downloads finish or fail", isOn: $settingsStore.values.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Destination") {
                HStack {
                    TextField("Download Folder", text: $settingsStore.values.downloadDirectory)
                    Button("Choose…") { chooseDirectory() }
                }
                if !settingsStore.values.favoriteDirectories.isEmpty {
                    LabeledContent("Favorite folders") {
                        Text(String(settingsStore.values.favoriteDirectories.count))
                    }
                }
            }

            Section("File Categories") {
                Toggle("Route downloads by file extension", isOn: $settingsStore.values.fileCategorizationEnabled)
                ForEach($settingsStore.values.fileCategories) { $category in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Category", text: $category.name)
                            TextField("Destination", text: $category.directory)
                            Button(role: .destructive) {
                                settingsStore.values.fileCategories.removeAll { $0.id == category.id }
                            } label: {
                                Label("Remove Category", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                        }
                        TextField(
                            "Extensions separated by commas",
                            text: Binding(
                                get: { category.extensions.joined(separator: ", ") },
                                set: { category.extensions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
                            )
                        )
                    }
                    .disabled(!settingsStore.values.fileCategorizationEnabled)
                }
                HStack {
                    Button("Add Category") {
                        settingsStore.values.fileCategories.append(
                            .init(name: "New Category", extensions: [], directory: settingsStore.values.downloadDirectory)
                        )
                    }
                    Button("Install Common Categories") { installCommonCategories() }
                        .disabled(!settingsStore.values.fileCategories.isEmpty)
                }
            }

            Section("Concurrency") {
                Stepper("Concurrent downloads: \(settingsStore.values.maxConcurrentDownloads)", value: $settingsStore.values.maxConcurrentDownloads, in: 1 ... 100)
                Stepper("Segments per file: \(settingsStore.values.split)", value: $settingsStore.values.split, in: 1 ... 256)
                Stepper("Connections per server: \(settingsStore.values.maxConnectionsPerServer)", value: $settingsStore.values.maxConnectionsPerServer, in: 1 ... 256)
                Toggle("Resume partial downloads", isOn: $settingsStore.values.continueDownloads)
                Toggle("Rename when filename already exists", isOn: $settingsStore.values.autoFileRenaming)
                Picker("File allocation", selection: $settingsStore.values.fileAllocation) {
                    Text("None").tag("none")
                    Text("Preallocate").tag("prealloc")
                    Text("Truncate").tag("trunc")
                    Text("Falloc").tag("falloc")
                }
            }

            Section {
                TextField("Global download", text: $settingsStore.values.globalDownloadLimit)
                TextField("Global upload", text: $settingsStore.values.globalUploadLimit)
                TextField("Per-task download", text: $settingsStore.values.perTaskDownloadLimit)
                TextField("Per-task upload", text: $settingsStore.values.perTaskUploadLimit)
                SpeedScheduleEditor(settingsStore: settingsStore)
            } header: {
                Text("Speed Limits")
            } footer: {
                Text("Use 0 for unlimited. Units may be written as K or M, for example 20M.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settingsStore.values.downloadDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.values.downloadDirectory = url.path
        }
    }

    private func installCommonCategories() {
        let base = URL(fileURLWithPath: settingsStore.values.downloadDirectory)
        settingsStore.values.fileCategories = [
            .init(name: "Videos", extensions: ["mp4", "mkv", "mov", "webm", "avi"], directory: base.appending(path: "Videos").path),
            .init(name: "Music", extensions: ["mp3", "flac", "m4a", "wav", "opus"], directory: base.appending(path: "Music").path),
            .init(name: "Images", extensions: ["jpg", "jpeg", "png", "gif", "webp"], directory: base.appending(path: "Images").path),
            .init(name: "Documents", extensions: ["pdf", "doc", "docx", "xls", "xlsx", "txt", "md"], directory: base.appending(path: "Documents").path),
            .init(name: "Archives", extensions: ["zip", "rar", "7z", "tar", "gz", "dmg", "iso"], directory: base.appending(path: "Archives").path),
        ]
        settingsStore.values.fileCategorizationEnabled = true
    }
}

private struct SpeedScheduleEditor: View {
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        DisclosureGroup("Scheduled limits") {
            Toggle("Enable schedule", isOn: $settingsStore.values.speedSchedule.enabled)
            HStack {
                Stepper("From \(settingsStore.values.speedSchedule.startHour):00", value: $settingsStore.values.speedSchedule.startHour, in: 0 ... 23)
                Stepper("to \(settingsStore.values.speedSchedule.endHour):00", value: $settingsStore.values.speedSchedule.endHour, in: 0 ... 23)
            }
            TextField("Scheduled download limit", text: $settingsStore.values.speedSchedule.downloadLimit)
            TextField("Scheduled upload limit", text: $settingsStore.values.speedSchedule.uploadLimit)
            HStack(spacing: 6) {
                ForEach(Array(zip(["M", "T", "W", "T", "F", "S", "S"], 1 ... 7)), id: \.1) { label, weekday in
                    Toggle(label, isOn: weekdayBinding(weekday))
                        .toggleStyle(.button)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .accessibilityLabel(weekdayName(weekday))
                }
            }
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settingsStore.values.speedSchedule.weekdays.contains(weekday) },
            set: { selected in
                if selected { settingsStore.values.speedSchedule.weekdays.insert(weekday) }
                else { settingsStore.values.speedSchedule.weekdays.remove(weekday) }
            }
        )
    }

    private func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[(weekday % 7)]
    }
}

private struct BitTorrentSettings: View {
    @Bindable var settingsStore: SettingsStore
    @State private var trackerText = ""

    var body: some View {
        Form {
            Section("Discovery") {
                Toggle("Distributed hash table (IPv4)", isOn: $settingsStore.values.enableDHT)
                Toggle("Distributed hash table (IPv6)", isOn: $settingsStore.values.enableDHT6)
                Toggle("Peer exchange", isOn: $settingsStore.values.enablePeerExchange)
                Toggle("Local peer discovery", isOn: $settingsStore.values.enableLocalPeerDiscovery)
                Toggle("Require encrypted peer connections", isOn: $settingsStore.values.forceEncryption)
            }

            Section("Connections") {
                Stepper("Maximum peers: \(settingsStore.values.btMaxPeers)", value: $settingsStore.values.btMaxPeers, in: 1 ... 500)
                TextField("BT listen port", value: $settingsStore.values.btListenPort, format: .number)
                TextField("DHT listen port", value: $settingsStore.values.dhtListenPort, format: .number)
                TextField("ED2K TCP port", value: $settingsStore.values.ed2kListenPort, format: .number)
                TextField("ED2K UDP port", value: $settingsStore.values.ed2kUDPListenPort, format: .number)
            }

            Section("Sharing") {
                LabeledContent("Seed ratio") {
                    TextField("Ratio", value: $settingsStore.values.seedRatio, format: .number.precision(.fractionLength(1)))
                        .frame(width: 90)
                }
                Stepper("Seed time: \(settingsStore.values.seedTimeMinutes) minutes", value: $settingsStore.values.seedTimeMinutes, in: 0 ... 100_800, step: 60)
                Toggle("Pause after magnet metadata arrives", isOn: $settingsStore.values.pauseMetadata)
            }

            Section("Tracker Sources") {
                TextEditor(text: $trackerText)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .onAppear { trackerText = settingsStore.values.trackerURLs.joined(separator: "\n") }
                    .onChange(of: trackerText) { _, value in
                        settingsStore.values.trackerURLs = value.split(whereSeparator: \.isNewline).map(String.init)
                    }
            }

            Section("Peer Blocklist") {
                Toggle("Enable BT peer blocklist", isOn: $settingsStore.values.enablePeerBlocklist)
                TextField("Blocklist URL", text: $settingsStore.values.peerBlocklistURL)
                    .disabled(!settingsStore.values.enablePeerBlocklist)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    @Bindable var settingsStore: SettingsStore
    let downloadStore: DownloadStore

    var body: some View {
        Form {
            Section("Proxy") {
                Picker("Mode", selection: $settingsStore.values.proxyMode) {
                    ForEach(AppSettings.ProxyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                TextField("Proxy URL", text: $settingsStore.values.proxyURL)
                    .disabled(settingsStore.values.proxyMode != .manual)
                TextField("Username", text: $settingsStore.values.proxyUsername)
                    .disabled(settingsStore.values.proxyMode != .manual)
                SecureField("Password", text: $settingsStore.proxyPassword)
                    .disabled(settingsStore.values.proxyMode != .manual)
                TextField("Bind transfers to network interface", text: $settingsStore.values.features.networkPolicy.bindInterface)
                Toggle("Do not fall back to a direct connection", isOn: $settingsStore.values.features.networkPolicy.noDirectFallback)
                    .disabled(settingsStore.values.proxyMode == .none)
            }

            Section("Local Integrations") {
                Toggle("Browser extension API", isOn: $settingsStore.values.extensionServerEnabled)
                TextField("Extension API port", value: $settingsStore.values.extensionServerPort, format: .number)
                    .disabled(!settingsStore.values.extensionServerEnabled)
                if let port = downloadStore.extensionAPIPort {
                    LabeledContent("Listening address", value: "127.0.0.1:\(port)")
                }
                LabeledContent("Access secret") {
                    Text(settingsStore.values.extensionSecret)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Text("The service listens on localhost only. Treat the secret like a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Browser Extension Packages") {
                    let projectPackages = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appending(path: "dist/browser-extensions", directoryHint: .isDirectory)
                    let bundledPackages = Bundle.main.resourceURL?.appending(path: "BrowserExtensions", directoryHint: .isDirectory)
                    if FileManager.default.fileExists(atPath: projectPackages.path) {
                        NSWorkspace.shared.open(projectPackages)
                    } else if let bundledPackages {
                        NSWorkspace.shared.open(bundledPackages)
                    }
                }
            }

            Section("Remote Control") {
                Toggle("Enable remote Web UI and MDXP", isOn: $settingsStore.values.features.remote.enabled)
                Toggle("Allow connections from the local network", isOn: $settingsStore.values.features.remote.allowLAN)
                    .disabled(!settingsStore.values.features.remote.enabled)
                TextField("Remote port", value: $settingsStore.values.features.remote.port, format: .number)
                    .disabled(!settingsStore.values.features.remote.enabled)
                if let port = downloadStore.remoteAPIPort {
                    LabeledContent("Web UI") {
                        Link("http://127.0.0.1:\(port)", destination: URL(string: "http://127.0.0.1:\(port)")!)
                    }
                }
                LabeledContent("Remote secret") {
                    Text(settingsStore.values.features.remote.secret)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Text("LAN access is disabled by default. Remote requests require a Bearer token; Internet exposure requires a trusted TLS reverse proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Peer Connectivity") {
                Toggle("UPnP port mapping", isOn: $settingsStore.values.features.networkPolicy.enableUPnP)
                Toggle("NAT-PMP port mapping", isOn: $settingsStore.values.features.networkPolicy.enableNATPMP)
                TextField("GeoIP database URL", text: $settingsStore.values.features.networkPolicy.geoIPDatabaseURL)
                LabeledContent("Port mapping", value: downloadStore.portMappingState.title)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Bindable var settingsStore: SettingsStore
    let downloadStore: DownloadStore
    @Binding var showingResetConfirmation: Bool

    var body: some View {
        Form {
            Section("Engine") {
                TextField("RPC port", value: $settingsStore.values.rpcPort, format: .number)
                TextField("User agent", text: $settingsStore.values.userAgent)
                LabeledContent("Engine") { Text("aria2-next 2.5.5") }
                LabeledContent("Interface") { Text("JSON-RPC 2.0 over localhost") }
            }

            Section("Data") {
                Button("Open Application Support Folder") {
                    if let url = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "SuperDD") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Export Diagnostics…") { exportDiagnostics() }
                Button("Restore All Settings…", role: .destructive) {
                    showingResetConfirmation = true
                }
            }

            Section("Resolver Plugins") {
                Toggle("Enable JavaScript resolver plugins", isOn: $settingsStore.values.features.plugins.enabled)
                TextField("Registry JSON URL", text: $settingsStore.values.features.plugins.registryURL)
                if downloadStore.availablePlugins.isEmpty {
                    Text("No plugins installed").foregroundStyle(.secondary)
                } else {
                    ForEach(downloadStore.availablePlugins) { plugin in
                        LabeledContent(plugin.name) {
                            Text("\(plugin.version) · \(plugin.id)").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Open Plugins Folder") { Task { await downloadStore.openPluginsDirectory() } }
                    Button("Reload") { Task { await downloadStore.reloadPlugins() } }
                    Button("Refresh Catalog") { Task { await downloadStore.refreshPluginCatalog() } }
                }
                if !downloadStore.pluginStatus.isEmpty { Text(downloadStore.pluginStatus).foregroundStyle(.secondary) }
                ForEach(downloadStore.pluginCatalog) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(item.version).foregroundStyle(.secondary)
                        Button("Install") { Task { await downloadStore.installPlugin(item) } }
                    }
                }
                Text("Each plugin runs in a separate JavaScriptCore helper process with no filesystem or network bridge and a five-second timeout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $settingsStore.values.features.updates.automaticallyChecks)
                TextField("Release feed", text: $settingsStore.values.features.updates.feedURL)
                LabeledContent("Status", value: downloadStore.updateStatus)
                HStack {
                    Button("Check Now") { Task { await downloadStore.checkForUpdates() } }
                    if let update = downloadStore.availableUpdate {
                        Button("Download and Verify \(update.version)") { Task { await downloadStore.downloadAvailableUpdate() } }
                            .buttonStyle(.borderedProminent)
                        Link("Release Notes", destination: update.webURL)
                    }
                }
                Text("Updates are accepted only when the release includes a matching SHA-256 checksum. macOS verifies Developer ID and notarization when the downloaded DMG or app is opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SuperDD-Diagnostics-\(ISO8601DateFormatter().string(from: .now).prefix(10)).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await downloadStore.exportDiagnostics(to: url) }
    }
}
