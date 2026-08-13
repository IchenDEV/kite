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
    @State private var previews: [String: PreviewState] = [:]
    @State private var selectedURLs: Set<String>
    @State private var knownURLs: Set<String>
    @State private var importedContainer: ImportedContainerDraft?
    @State private var importedFileSelection = Set<Int>()
    @State private var isImportingContainer = false
    @State private var activeContainerImportID: UUID?
    @FocusState private var inputFocused: Bool

    private let previewService = DownloadPreviewService()

    init(store: DownloadStore) {
        self.store = store
        let initialInput = store.pendingAddURLs.joined(separator: "\n")
        let initialURLs = Set(DownloadURLNormalizer.extractMany(from: initialInput))
        _input = State(initialValue: initialInput)
        _selectedURLs = State(initialValue: initialURLs)
        _knownURLs = State(initialValue: initialURLs)
        _options = State(initialValue: AddTaskOptions(directory: store.settingsStore.values.downloadDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Download")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Open Torrent or Metalink…") { showingTorrentImporter = true }
            }

            if let importedContainer {
                ImportedContainerPreview(
                    draft: importedContainer,
                    selectedIndices: $importedFileSelection,
                    onRemove: {
                        self.importedContainer = nil
                        importedFileSelection.removeAll()
                    }
                )
            } else if isImportingContainer {
                GroupBox("Preview") {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading container metadata…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                }
            } else {
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .frame(minHeight: 96)
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

                inputSummary

                if !analysis.accepted.isEmpty {
                    previewList
                }
            }

            HStack {
                TextField("Download Folder", text: $options.directory)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    if !store.settingsStore.values.favoriteDirectories.isEmpty {
                        Section("Favorites") {
                            ForEach(store.settingsStore.values.favoriteDirectories, id: \.self) { directory in
                                Button(action: { selectDirectory(directory) }) {
                                    Text(directory)
                                }
                            }
                        }
                    }
                    if !store.settingsStore.values.recentDirectories.isEmpty {
                        Section("Recent") {
                            ForEach(store.settingsStore.values.recentDirectories, id: \.self) { directory in
                                Button(action: { selectDirectory(directory) }) {
                                    Text(directory)
                                }
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

            destinationSummary

            DisclosureGroup("Options", isExpanded: $showingAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    filenameFieldRow
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
                    let urls = analysis.accepted.filter(selectedURLs.contains)
                    store.pendingAddURLs = []
                    if let importedContainer {
                        var submissionOptions = options
                        if importedContainer.preview.files.count > 1 {
                            submissionOptions.filename = ""
                            if importedFileSelection.count < importedContainer.preview.files.count {
                                submissionOptions.selectedFileIndices = importedFileSelection
                            }
                        }
                        Task {
                            if importedContainer.preview.kind == .metalink {
                                await store.addMetalink(at: importedContainer.url, options: submissionOptions)
                            } else {
                                await store.addTorrent(at: importedContainer.url, options: submissionOptions)
                            }
                        }
                    } else {
                        var submissionOptions = options
                        if urls.count > 1 { submissionOptions.filename = "" }
                        Task { await store.addURLs(urls, options: submissionOptions) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 720)
        .task {
            inputFocused = true
            if let url = store.pendingContainerURL {
                await importContainer(at: url)
            }
        }
        .task(id: previewRequestKey) {
            guard importedContainer == nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            await refreshPreviews()
        }
        .onChange(of: previewInputKey) { _, _ in
            synchronizeURLSelection()
        }
        .onChange(of: store.pendingAddURLs) { _, urls in
            appendPendingURLs(urls)
        }
        .onChange(of: store.pendingContainerURL) { _, url in
            guard let url else { return }
            Task { await importContainer(at: url) }
        }
        .onDisappear {
            store.pendingAddURLs = []
            store.pendingContainerURL = nil
        }
        .fileImporter(
            isPresented: $showingTorrentImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "torrent") ?? .data,
                UTType(filenameExtension: "metalink") ?? .xml,
                UTType(filenameExtension: "meta4") ?? .xml,
            ],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result else { return }
            guard let url = urls.first else { return }
            Task { await importContainer(at: url) }
        }
    }

    private var analysis: DownloadURLAnalysis {
        DownloadURLNormalizer.analyze(input)
    }

    private var previewInputKey: String {
        analysis.accepted.joined(separator: "\n")
    }

    private var previewRequestKey: String {
        [
            previewInputKey,
            options.referer,
            options.userAgent,
            options.cookie,
            options.headers,
            options.credentialProfileID?.uuidString ?? "automatic",
            store.settingsStore.values.userAgent,
            store.settingsStore.values.features.credentialProfiles
                .map { "\($0.id):\($0.hostPattern):\($0.username):\($0.sendsCookie)" }
                .joined(separator: "|"),
        ].joined(separator: "\u{1F}")
    }

    private var canSubmit: Bool {
        let hasContainerSource = importedContainer.map {
            $0.preview.error == nil && !$0.preview.files.isEmpty && !importedFileSelection.isEmpty
        } ?? false
        let hasURLSource = analysis.accepted.contains(where: selectedURLs.contains)
        return (hasContainerSource || hasURLSource)
            && !options.directory.isEmpty
            && !store.isBusy
            && !isImportingContainer
            && store.canAddDownloads
    }

    @ViewBuilder
    private var inputSummary: some View {
        let result = analysis
        if result.inputCount > 0 {
            HStack(spacing: 12) {
                Label("\(selectedURLs.count) of \(result.accepted.count) selected", systemImage: "checkmark.circle")
                    .foregroundStyle(result.accepted.isEmpty ? Color.secondary : Color.green)
                if result.duplicateCount > 0 {
                    Label("\(result.duplicateCount) duplicate", systemImage: "doc.on.doc")
                }
                if !result.rejected.isEmpty {
                    Label("\(result.rejected.count) invalid", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(result.rejected.joined(separator: "\n"))
                }
                Spacer()
                if !store.canAddDownloads {
                    Label(store.engineState.title, systemImage: "engine.combustion")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var previewList: some View {
        DownloadPreviewList(urls: analysis.accepted, previews: previews, selectedURLs: $selectedURLs)
    }

    private func refreshPreviews() async {
        let urls = analysis.accepted
        guard !urls.isEmpty else { return }
        previews = Dictionary(uniqueKeysWithValues: urls.map { ($0, .checking) })
        let requests = urls.map { url in
            (url, store.previewHeaders(for: options, source: url))
        }

        await withTaskGroup(of: (String, PreviewState)?.self) { group in
            var iterator = requests.makeIterator()
            let maximumConcurrentPreviews = 4
            for _ in 0 ..< min(maximumConcurrentPreviews, requests.count) {
                guard let request = iterator.next() else { break }
                addPreviewTask(request, to: &group)
            }
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let (url, state) = result {
                    previews[url] = state
                }
                if let request = iterator.next() {
                    addPreviewTask(request, to: &group)
                }
            }
        }
    }

    private func addPreviewTask(
        _ request: (String, [String: String]),
        to group: inout TaskGroup<(String, PreviewState)?>
    ) {
        let (url, headers) = request
        group.addTask {
            do {
                return (url, .ready(try await previewService.preview(url, headers: headers)))
            } catch is CancellationError {
                return nil
            } catch {
                return (url, .failed(error.localizedDescription))
            }
        }
    }

    @ViewBuilder
    private var filenameFieldRow: some View {
        GridRow {
            Text("Filename").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Use server filename", text: $options.filename)
                    .disabled(disablesCustomFilename)
                if let filenameGuidance {
                    Text(filenameGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var disablesCustomFilename: Bool {
        if let importedContainer {
            return importedContainer.preview.files.count > 1
        }
        return analysis.accepted.filter(selectedURLs.contains).count > 1
    }

    private var filenameGuidance: String? {
        if let importedContainer, importedContainer.preview.files.count > 1 {
            return "Multi-file containers keep their embedded filenames."
        }
        if analysis.accepted.filter(selectedURLs.contains).count > 1 {
            return "Select one URL to set a custom filename."
        }
        return nil
    }

    @ViewBuilder
    private var destinationSummary: some View {
        HStack(spacing: 12) {
            if let selectedContentLength {
                Label("Selected size: \(Formatters.byteCount(selectedContentLength))", systemImage: "externaldrive")
            } else {
                Label("Selected size: Unknown", systemImage: "externaldrive")
            }
            if let availableCapacity {
                Label("Available: \(Formatters.byteCount(availableCapacity))", systemImage: "internaldrive")
                    .foregroundStyle(hasEnoughCapacity == false ? .orange : .secondary)
            }
            Spacer()
            Text("Existing files: \(store.settingsStore.values.features.reliability.conflictPolicy.title)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var selectedContentLength: Int64? {
        if let importedContainer {
            let lengths = importedContainer.preview.files.enumerated().compactMap { offset, file in
                importedFileSelection.contains(offset + 1) ? file.length : nil
            }
            guard lengths.count == importedFileSelection.count else { return nil }
            return DownloadSizeSummary.total(lengths)
        }
        let selected = analysis.accepted.filter(selectedURLs.contains)
        let lengths = selected.compactMap { url -> Int64? in
            guard case let .ready(preview)? = previews[url] else { return nil }
            return preview.contentLength
        }
        guard !selected.isEmpty, lengths.count == selected.count else { return nil }
        return DownloadSizeSummary.total(lengths)
    }

    private var availableCapacity: Int64? {
        let directory = URL(fileURLWithPath: options.directory, isDirectory: true)
        return try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private var hasEnoughCapacity: Bool? {
        guard let selectedContentLength, let availableCapacity else { return nil }
        return selectedContentLength <= availableCapacity
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

    private func synchronizeURLSelection() {
        let current = Set(analysis.accepted)
        selectedURLs.formIntersection(current)
        selectedURLs.formUnion(current.subtracting(knownURLs))
        knownURLs = current
    }

    private func importContainer(at url: URL) async {
        let importID = UUID()
        activeContainerImportID = importID
        isImportingContainer = true
        let preview = await Task.detached(priority: .userInitiated) {
            return ContainerPreviewService().preview(fileAt: url)
        }.value
        guard !Task.isCancelled, activeContainerImportID == importID else { return }
        importedContainer = ImportedContainerDraft(url: url, preview: preview)
        importedFileSelection = Set(preview.files.indices.map { $0 + 1 })
        input = ""
        previews = [:]
        selectedURLs = []
        knownURLs = []
        store.pendingContainerURL = nil
        activeContainerImportID = nil
        isImportingContainer = false
    }

    private func selectDirectory(_ directory: String) {
        options.directory = directory
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

private struct DownloadPreviewList: View {
    let urls: [String]
    let previews: [String: PreviewState]
    @Binding var selectedURLs: Set<String>

    var body: some View {
        GroupBox {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        Toggle(isOn: selectionBinding(for: url)) {
                            DownloadPreviewRow(url: url, state: previews[url] ?? .checking)
                        }
                        .toggleStyle(.checkbox)
                        if index < urls.count - 1 { Divider() }
                    }
                }
            }
            .frame(minHeight: 82, maxHeight: 190)
        } label: {
            HStack {
                Text("Preview")
                Spacer()
                Button("All") { selectedURLs = Set(urls) }
                    .buttonStyle(.link)
                Button("None") { selectedURLs.removeAll() }
                    .buttonStyle(.link)
            }
        }
    }

    private func selectionBinding(for url: String) -> Binding<Bool> {
        Binding(
            get: { selectedURLs.contains(url) },
            set: { selected in
                if selected { selectedURLs.insert(url) }
                else { selectedURLs.remove(url) }
            }
        )
    }
}

private struct ImportedContainerDraft {
    let url: URL
    let preview: ContainerPreview
}

private enum PreviewState: Equatable, Sendable {
    case checking
    case ready(DownloadPreview)
    case failed(String)
}

private struct DownloadPreviewRow: View {
    let url: String
    let state: PreviewState

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case let .ready(preview) = state {
                Text(preview.contentLength.map(Formatters.byteCount) ?? "Unknown size")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusIcon: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case let .ready(preview):
            if preview.usesNetworkPreview {
                Image(systemName: preview.isReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(preview.isReachable ? .green : .orange)
            } else {
                Image(systemName: "doc.badge.checkmark")
                    .foregroundStyle(.blue)
            }
        case .failed:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch state {
        case .checking:
            return URL(string: url)?.lastPathComponent.removingPercentEncoding.nonempty ?? "Checking link…"
        case let .ready(preview):
            return preview.displayName
        case .failed:
            return URL(string: url)?.host ?? url
        }
    }

    private var detail: String {
        switch state {
        case .checking:
            "Checking type, size, and availability…"
        case let .ready(preview):
            [
                preview.protocolKind.title,
                preview.usesNetworkPreview ? nil : "Link parsed",
                preview.mimeType,
                preview.host,
                preview.statusCode.map(String.init),
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
        case let .failed(message):
            "Preview unavailable · \(message) · You can still add this link."
        }
    }
}

private struct ImportedContainerPreview: View {
    let draft: ImportedContainerDraft
    @Binding var selectedIndices: Set<Int>
    let onRemove: () -> Void

    var body: some View {
        GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: draft.preview.kind == .torrent ? "point.3.connected.trianglepath.dotted" : "doc.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.preview.displayName)
                            .font(.headline)
                        Text(containerSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "xmark", action: onRemove)
                        .labelStyle(.iconOnly)
                        .help("Remove imported file")
                }
                if let error = draft.preview.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !draft.preview.files.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(draft.preview.files.enumerated()), id: \.offset) { offset, file in
                                Toggle(isOn: selectionBinding(for: offset + 1)) {
                                    HStack {
                                        Text(file.relativePath).lineLimit(1)
                                        Spacer()
                                        Text(file.length.map(Formatters.byteCount) ?? "Unknown size")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                    HStack {
                        Text("\(selectedIndices.count) of \(draft.preview.files.count) files selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("All") { selectedIndices = Set(draft.preview.files.indices.map { $0 + 1 }) }
                            .buttonStyle(.link)
                        Button("None") { selectedIndices.removeAll() }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(4)
        }
    }

    private var containerSummary: String {
        var parts = [draft.preview.kind.title, "\(draft.preview.fileCount) files"]
        if let length = draft.preview.totalLength { parts.append(Formatters.byteCount(length)) }
        if let trackers = draft.preview.trackerCount { parts.append("\(trackers) trackers") }
        return parts.joined(separator: " · ")
    }

    private func selectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndices.contains(index) },
            set: { selected in
                if selected { selectedIndices.insert(index) }
                else { selectedIndices.remove(index) }
            }
        )
    }
}

private extension Optional where Wrapped == String {
    var nonempty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
