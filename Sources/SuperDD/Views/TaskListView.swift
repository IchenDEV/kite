import SwiftUI

struct TaskListView: View {
    @Bindable var store: DownloadStore

    var body: some View {
        Group {
            if store.visibleTasks.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyImage)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if store.section == .all {
                        Button("New Download") { store.showingAddTask = true }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                List(selection: $store.selectedTaskIDs) {
                    ForEach(store.visibleTasks) { task in
                        TaskRowView(task: task)
                            .tag(task.gid)
                            .contextMenu { contextMenu(for: task) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .glassEffect(.regular, in: .circle)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for task: DownloadTask) -> some View {
        if task.status == .paused {
            Button("Resume") {
                store.selectedTaskIDs = [task.gid]
                Task { await store.resumeSelection() }
            }
        } else if task.status == .active || task.status == .waiting || task.status == .sharing {
            Button("Pause") {
                store.selectedTaskIDs = [task.gid]
                Task { await store.pauseSelection() }
            }
        }

        if task.status == .complete {
            Button("Open") { store.open(task) }
            Button("Reveal in Finder") { store.reveal(task) }
        }

        Button("Copy Source URL") { store.copySourceURL(task) }
            .disabled(task.files.first?.uris.first == nil)

        Divider()

        Button("Remove", role: .destructive) {
            store.selectedTaskIDs = [task.gid]
            Task { await store.removeSelection() }
        }
    }

    private var emptyTitle: String {
        switch store.section {
        case .all: "No Downloads"
        case .downloading: "Nothing Downloading"
        case .waiting: "No Waiting Downloads"
        case .completed: "No Completed Downloads"
        case .failed: "No Failed Downloads"
        default: "No Downloads"
        }
    }

    private var emptyImage: String {
        switch store.section {
        case .failed: "checkmark.shield"
        case .completed: "checkmark.circle"
        case .waiting: "clock"
        default: "arrow.down.circle"
        }
    }

    private var emptyDescription: String {
        store.searchText.isEmpty ? "Downloads matching this view appear here." : "No downloads match your search."
    }
}

private struct TaskRowView: View {
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.status.systemImage)
                .font(.title3)
                .foregroundStyle(statusStyle)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(task.status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(Formatters.percent(task.progress))

                HStack(spacing: 12) {
                    Text("\(Formatters.byteCount(task.completedLength)) of \(Formatters.byteCount(task.totalLength))")
                    if task.status == .active {
                        Text("↓ \(Formatters.speed(task.downloadSpeed))")
                        Text(Formatters.duration(task.estimatedSecondsRemaining))
                    } else if task.status == .sharing {
                        Text("↑ \(Formatters.speed(task.uploadSpeed))")
                    } else if task.status == .error, let message = task.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                    Spacer()
                    Text(Formatters.percent(task.progress))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.name), \(task.status.title), \(Formatters.percent(task.progress))")
    }

    private var statusStyle: AnyShapeStyle {
        switch task.status {
        case .error: AnyShapeStyle(.red)
        case .complete: AnyShapeStyle(.green)
        case .active, .sharing: AnyShapeStyle(.tint)
        default: AnyShapeStyle(.secondary)
        }
    }
}
