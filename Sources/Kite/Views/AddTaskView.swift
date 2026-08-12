import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let store: DownloadStore
    @State private var input = ""
    @State private var options: AddTaskOptions
    @State private var showingAdvanced = false
    @State private var showingTorrentImporter = false
    @FocusState private var inputFocused: Bool

    init(store: DownloadStore) {
        self.store = store
        _input = State(initialValue: store.pendingAddURLs.joined(separator: "\n"))
        _options = State(initialValue: AddTaskOptions(directory: store.settingsStore.values.downloadDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Download")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Open Torrent or Metalink…") { showingTorrentImporter = true }
            }

            TextEditor(text: $input)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.fill.quaternary, in: .rect(cornerRadius: 8))
                .focused($inputFocused)
                .accessibilityLabel("Download URLs")
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Paste HTTP, FTP, magnet, ED2K, or Thunder links. Use one link per line.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                TextField("Download Folder", text: $options.directory)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    if !store.settingsStore.values.favoriteDirectories.isEmpty {
                        Section("Favorites") {
                            ForEach(store.settingsStore.values.favoriteDirectories, id: \.self) { directory in
                                Button(directory) { options.directory = directory }
                            }
                        }
                    }
                    if !store.settingsStore.values.recentDirectories.isEmpty {
                        Section("Recent") {
                            ForEach(store.settingsStore.values.recentDirectories, id: \.self) { directory in
                                Button(directory) { options.directory = directory }
                            }
                        }
                    }
                } label: {
                    Label("Saved Folders", systemImage: "folder.badge.gearshape")
                }
                .menuIndicator(.hidden)
                .help("Favorite and Recent Folders")
                Button("Choose…") { chooseDirectory() }
                Button {
                    store.toggleFavoriteDirectory(options.directory)
                } label: {
                    Label(
                        store.settingsStore.values.favoriteDirectories.contains(options.directory) ? "Remove Favorite" : "Add Favorite",
                        systemImage: store.settingsStore.values.favoriteDirectories.contains(options.directory) ? "star.fill" : "star"
                    )
                }
                .labelStyle(.iconOnly)
                .help(store.settingsStore.values.favoriteDirectories.contains(options.directory) ? "Remove from Favorites" : "Add to Favorites")
            }

            DisclosureGroup("Options", isExpanded: $showingAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    fieldRow("Filename", text: $options.filename, prompt: "Use server filename")
                    fieldRow("Referer", text: $options.referer, prompt: "https://example.com/")
                    fieldRow("User Agent", text: $options.userAgent, prompt: store.settingsStore.values.userAgent)
                    fieldRow("Cookie", text: $options.cookie, prompt: "name=value")
                    fieldRow("Checksum", text: $options.checksum, prompt: "sha-256=…")
                    fieldRow("Proxy", text: $options.proxy, prompt: "http://127.0.0.1:8080")
                    GridRow {
                        Text("Headers").foregroundStyle(.secondary)
                        TextField("One header per line", text: $options.headers, axis: .vertical)
                            .lineLimit(2 ... 5)
                    }
                    GridRow {
                        Text("")
                        HStack {
                            Toggle("Add paused", isOn: $options.paused)
                            Toggle("Scheduled", isOn: $options.scheduled)
                        }
                    }
                    GridRow {
                        Text("Priority").foregroundStyle(.secondary)
                        Picker("Priority", selection: $options.priority) {
                            ForEach(TaskPriority.allCases) { priority in
                                Text(priority.title).tag(priority)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Credential").foregroundStyle(.secondary)
                        Picker("Credential", selection: $options.credentialProfileID) {
                            Text("Automatic / None").tag(UUID?.none)
                            ForEach(store.settingsStore.values.features.credentialProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Label").foregroundStyle(.secondary)
                        TextField("Optional task label", text: $options.label)
                    }
                }
                .padding(.top, 10)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let urls = DownloadURLNormalizer.extractMany(from: input)
                    store.pendingAddURLs = []
                    Task { await store.addURLs(urls, options: options) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(DownloadURLNormalizer.extractMany(from: input).isEmpty || options.directory.isEmpty || store.isBusy)
            }
        }
        .padding(22)
        .frame(width: 600)
        .task { inputFocused = true }
        .onChange(of: store.pendingAddURLs) { _, urls in
            appendPendingURLs(urls)
        }
        .onDisappear { store.pendingAddURLs = [] }
        .fileImporter(
            isPresented: $showingTorrentImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "torrent") ?? .data,
                UTType(filenameExtension: "metalink") ?? .xml,
                UTType(filenameExtension: "meta4") ?? .xml,
            ],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                Task {
                    if ["metalink", "meta4"].contains(url.pathExtension.lowercased()) {
                        await store.addMetalink(at: url, options: options)
                    } else {
                        await store.addTorrent(at: url, options: options)
                    }
                }
            }
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(prompt, text: text)
        }
    }

    private func appendPendingURLs(_ urls: [String]) {
        let existing = Set(DownloadURLNormalizer.extractMany(from: input))
        let additions = urls.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        if !input.isEmpty, !input.hasSuffix("\n") {
            input.append("\n")
        }
        input.append(additions.joined(separator: "\n"))
        inputFocused = true
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: options.directory)
        if panel.runModal() == .OK, let url = panel.url {
            options.directory = url.path
        }
    }
}
