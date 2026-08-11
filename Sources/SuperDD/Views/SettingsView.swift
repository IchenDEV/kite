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
            BitTorrentSettings(settingsStore: settingsStore)
                .tabItem { Label("BitTorrent", systemImage: "point.3.connected.trianglepath.dotted") }
            NetworkSettings(settingsStore: settingsStore, downloadStore: downloadStore)
                .tabItem { Label("Network", systemImage: "network") }
            AdvancedSettings(settingsStore: settingsStore, downloadStore: downloadStore, showingResetConfirmation: $showingResetConfirmation)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .scenePadding()
        .frame(width: 700, height: 520)
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
                SecureField("Password", text: $settingsStore.values.proxyPassword)
                    .disabled(settingsStore.values.proxyMode != .manual)
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
