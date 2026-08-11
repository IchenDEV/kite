import SwiftUI

struct SidebarView: View {
    @Bindable var store: DownloadStore

    var body: some View {
        List(selection: $store.section) {
            Section {
                sidebarRow(.dashboard)
            }

            Section("Downloads") {
                ForEach([AppSection.all, .downloading, .waiting, .completed, .failed]) { section in
                    sidebarRow(section)
                }
            }

            Section("Library") {
                sidebarRow(.history)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            EngineStatusView(store: store)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .navigationTitle("Super DD")
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Group {
            if let count = store.count(for: section) {
                Label(section.title, systemImage: section.systemImage)
                    .badge(count)
            } else {
                Label(section.title, systemImage: section.systemImage)
            }
        }
        .tag(section)
    }
}

private struct EngineStatusView: View {
    let store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                Text(store.engineState.title)
                    .lineLimit(1)
            }
            .font(.caption)

            if case .running = store.engineState {
                Text("↓ \(Formatters.speed(store.globalStat.downloadSpeed))  ↑ \(Formatters.speed(store.globalStat.uploadSpeed))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusImage: String {
        switch store.engineState {
        case .running: "checkmark.circle.fill"
        case .starting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    private var statusColor: Color {
        switch store.engineState {
        case .running: .green
        case .starting: .secondary
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
