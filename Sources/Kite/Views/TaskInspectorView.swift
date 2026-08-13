import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case overview
    case files
    case peers
    case trackers

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TaskInspectorView: View {
    @Bindable var store: DownloadStore
    @State private var tab: InspectorTab = .overview

    var body: some View {
        Group {
            if let task = store.selectedTask {
                VStack(spacing: 0) {
                    Picker("Inspector Section", selection: $tab) {
                        ForEach(availableTabs(for: task)) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .padding()

                    Divider()

                    switch tab {
                    case .overview:
                        TaskOverview(task: task)
                    case .files:
                        TaskFilesView(store: store, task: task)
                    case .peers:
                        PeerListView(peers: store.peers, countries: store.peerCountries)
                    case .trackers:
                        TrackerListView(trackers: task.trackers)
                    }
                }
                .navigationTitle("Task Inspector")
            } else if store.selectedTaskIDs.count > 1 {
                ContentUnavailableView(
                    "Multiple Downloads Selected",
                    systemImage: "checklist",
                    description: Text("Select one download to inspect its files and connection details.")
                )
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a download to inspect it.")
                )
            }
        }
        .onChange(of: store.selectedTask?.gid) { _, _ in
            tab = .overview
        }
    }

    private func availableTabs(for task: DownloadTask) -> [InspectorTab] {
        task.isBitTorrent ? InspectorTab.allCases : [.overview, .files]
    }
}

private struct TaskOverview: View {
    let task: DownloadTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    Label(task.status.title, systemImage: task.status.systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: task.progress)
                    .accessibilityValue(Formatters.percent(task.progress))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    detailRow("Progress", Formatters.percent(task.progress))
                    detailRow("Downloaded", Formatters.byteCount(task.completedLength))
                    detailRow("Total", Formatters.byteCount(task.totalLength))
                    detailRow("Download Speed", Formatters.speed(task.downloadSpeed))
                    detailRow("Upload Speed", Formatters.speed(task.uploadSpeed))
                    detailRow("Connections", String(task.connections))
                    detailRow("Remaining", Formatters.duration(task.estimatedSecondsRemaining))
                    if task.isBitTorrent {
                        detailRow("Seeders", String(task.numSeeders))
                        detailRow("Uploaded", Formatters.byteCount(task.uploadLength))
                        if let infoHash = task.infoHash { detailRow("Info Hash", infoHash) }
                    }
                    detailRow("GID", task.gid)
                    detailRow("Directory", task.directory)
                }
                .font(.callout)

                if let message = task.errorMessage, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

private struct TaskFilesView: View {
    let store: DownloadStore
    let task: DownloadTask
    @State private var selectedIndices = Set<Int>()

    var body: some View {
        VStack(spacing: 0) {
            List(task.files) { file in
                Toggle(isOn: binding(for: file.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).lineLimit(1)
                        HStack {
                            Text(Formatters.byteCount(file.length))
                            Text(Formatters.percent(file.progress))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(task.status == .complete || task.status == .error)
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                }
            }
            .listStyle(.inset)

            if task.status != .complete && task.status != .error {
                Divider()
                HStack {
                    Button("All") { selectedIndices = Set(task.files.map(\.id)) }
                    Spacer()
                    Button("Apply") {
                        Task { await store.setSelectedFiles(selectedIndices, task: task) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndices.isEmpty)
                }
                .controlSize(.small)
                .padding()
            }
        }
        .task(id: task.gid) {
            selectedIndices = Set(task.files.filter(\.selected).map(\.id))
        }
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndices.contains(index) },
            set: { selected in
                if selected { selectedIndices.insert(index) }
                else { selectedIndices.remove(index) }
            }
        )
    }
}

private struct PeerListView: View {
    let peers: [Peer]
    let countries: [String: String]

    var body: some View {
        if peers.isEmpty {
            ContentUnavailableView("No Peers", systemImage: "person.2.slash")
        } else {
            Table(peers) {
                TableColumn("Address") { peer in
                    Text("\(peer.ip):\(peer.port)").textSelection(.enabled)
                }
                TableColumn("Client") { peer in
                    Text(peer.client.isEmpty ? "Unknown" : peer.client)
                }
                TableColumn("Region") { peer in
                    Text(countries[peer.id] ?? "—")
                }
                TableColumn("Down") { peer in
                    Text(Formatters.speed(peer.downloadSpeed)).monospacedDigit()
                }
                TableColumn("Up") { peer in
                    Text(Formatters.speed(peer.uploadSpeed)).monospacedDigit()
                }
            }
        }
    }
}

private struct TrackerListView: View {
    let trackers: [String]

    var body: some View {
        if trackers.isEmpty {
            ContentUnavailableView("No Trackers", systemImage: "antenna.radiowaves.left.and.right.slash")
        } else {
            List(trackers, id: \.self) { tracker in
                Text(tracker)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .listStyle(.inset)
        }
    }
}
