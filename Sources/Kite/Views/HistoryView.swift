import SwiftUI

struct HistoryView: View {
    @Bindable var store: DownloadStore
    @State private var showingClearConfirmation = false

    var body: some View {
        Group {
            if store.visibleHistory.isEmpty {
                ContentUnavailableView(
                    store.searchText.isEmpty ? "No Download History" : "No Results",
                    systemImage: "archivebox",
                    description: Text(store.searchText.isEmpty ? "Completed and failed downloads are archived here." : "Try a different search.")
                )
            } else {
                Table(store.visibleHistory, selection: $store.selectedHistoryIDs) {
                    TableColumn("Name") { record in
                        HStack(spacing: 8) {
                            Image(systemName: record.status.systemImage)
                                .foregroundStyle(record.status == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            Text(record.name).lineLimit(1)
                        }
                        .contextMenu {
                            Button("Download Again") { Task { await store.retryHistory(record) } }
                                .disabled(!record.canRetry)
                            Button("Show Folder") { store.showInFinder(record) }
                            Divider()
                            Button("Remove from History", role: .destructive) {
                                store.selectedHistoryIDs = [record.id]
                                Task { await store.removeHistorySelection() }
                            }
                        }
                    }
                    .width(min: 260, ideal: 420)

                    TableColumn("Status") { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.status.title)
                            if !record.label.isEmpty {
                                Text(record.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(90)

                    TableColumn("Size") { record in
                        Text(Formatters.byteCount(record.totalLength)).monospacedDigit()
                    }
                    .width(90)

                    TableColumn("Finished") { record in
                        Text(record.completedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    .width(min: 140, ideal: 170)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("Remove Selected", role: .destructive) {
                        Task { await store.removeHistorySelection() }
                    }
                    .disabled(store.selectedHistoryIDs.isEmpty)
                    Button("Clear History…", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(store.history.isEmpty)
                } label: {
                    Label("History Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Clear all download history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await store.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files and active tasks are not removed.")
        }
    }
}
