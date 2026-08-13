import SwiftUI

struct ContentView: View {
    @Bindable var store: DownloadStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
                .navigationTitle(store.section.title)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        if let action = store.pendingCompletionAction {
                            HStack(spacing: 8) {
                                Image(systemName: "power")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(.primary)
                                Text("\(action.title) in \(store.completionCountdown) seconds")
                                    .font(.callout)
                                Spacer()
                                Button("Cancel") { store.cancelCompletionAction() }
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.bar)
                        }
                        if let error = store.lastError, !isFatalEngineError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.callout)
                                    .lineLimit(2)
                                Spacer()
                                Button("Dismiss") { store.lastError = nil }
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.bar)
                        }
                    }
                }
                .inspector(isPresented: $store.showingInspector) {
                    InspectorContentView(store: store)
                        .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search downloads")
        .symbolRenderingMode(.monochrome)
        .toolbar(id: "main") {
            ToolbarItem(id: "add", placement: .primaryAction) {
                Button { store.showingAddTask = true } label: {
                    Label("New Download", systemImage: "plus")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Download (⌘N)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(id: "pause", placement: .primaryAction) {
                Button { Task { await store.togglePauseSelection() } } label: {
                    Label(store.canPauseSelection ? "Pause" : "Resume", systemImage: store.canPauseSelection ? "pause" : "play")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .disabled(!store.canPauseSelection && !store.canResumeSelection)
                .help("Pause or Resume (⌘P)")
            }

            ToolbarItem(id: "remove", placement: .primaryAction) {
                Button(role: .destructive) { Task { await store.confirmRemovalOfSelection() } } label: {
                    Label("Remove", systemImage: "trash")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .disabled(store.selectedTaskIDs.isEmpty)
                .help("Remove Selected (⌘⌫)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(id: "speed", placement: .primaryAction) {
                SpeedToolbarItem(store: store)
            }

            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button { store.showingInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .help("Toggle Inspector (⌥⌘I)")
            }

            ToolbarItem(id: "settings", placement: .secondaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .help("Settings (⌘,)")
            }
        }
        .toolbarRole(.editor)
        .dropDestination(for: URL.self) { urls, _ in
            store.acceptDroppedURLs(urls)
        }
        .dropDestination(for: String.self) { values, _ in
            let urls = values.flatMap(DownloadURLNormalizer.extractMany)
            store.presentLinks(urls)
            return !urls.isEmpty
        }
        .sheet(isPresented: $store.showingAddTask) {
            AddTaskView(store: store)
        }
        .sheet(isPresented: $store.showingTorrentCreator) {
            TorrentCreatorView(store: store)
        }
        .alert("Download Engine", isPresented: errorBinding) {
            Button("Dismiss") { store.lastError = nil }
            if case .failed = store.engineState {
                Button("Retry") { Task { await store.restartEngine() } }
            }
        } message: {
            Text(store.lastError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.section {
        case .dashboard:
            DashboardView(store: store)
        case .history:
            HistoryView(store: store)
        default:
            TaskListView(store: store)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil && isFatalEngineError },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private var isFatalEngineError: Bool {
        if case .failed = store.engineState { return true }
        return false
    }
}

private struct InspectorContentView: View {
    let store: DownloadStore

    var body: some View {
        switch store.section {
        case .history:
            if let record = store.selectedHistoryRecord {
                Form {
                    LabeledContent("Name", value: record.name)
                    LabeledContent("Status", value: record.status.title)
                    LabeledContent("Size", value: Formatters.byteCount(record.totalLength))
                    LabeledContent("Finished") {
                        Text(record.completedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    LabeledContent("Folder", value: record.directory)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No History Selection", systemImage: "archivebox", description: Text("Select a record to inspect it."))
            }
        case .dashboard:
            Form {
                LabeledContent("Engine", value: store.engineState.title)
                LabeledContent("Download", value: Formatters.speed(store.globalStat.downloadSpeed))
                LabeledContent("Upload", value: Formatters.speed(store.globalStat.uploadSpeed))
                LabeledContent("Active", value: String(store.globalStat.numActive))
                LabeledContent("Waiting", value: String(store.globalStat.numWaiting))
                LabeledContent("Trackers", value: String(store.trackerCount))
            }
            .formStyle(.grouped)
        default:
            TaskInspectorView(store: store)
        }
    }
}

private struct SpeedToolbarItem: View {
    @Bindable var store: DownloadStore
    @State private var showingPopover = false

    var body: some View {
        Button { showingPopover.toggle() } label: {
            Label("Speed Limits", systemImage: "speedometer")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Download") {
                    Text(Formatters.speed(store.globalStat.downloadSpeed))
                        .monospacedDigit()
                }
                LabeledContent("Upload") {
                    Text(Formatters.speed(store.globalStat.uploadSpeed))
                        .monospacedDigit()
                }
                Divider()
                Text("Limits are configured in Settings → Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 250)
            .padding()
        }
        .help("Transfer Speed")
    }
}
