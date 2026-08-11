import Charts
import SwiftUI

struct DashboardView: View {
    let store: DownloadStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TransferSummary(store: store)

                if store.speedSamples.count > 1 {
                    Chart(store.speedSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Download", sample.download)
                        )
                        .foregroundStyle(by: .value("Direction", "Download"))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Upload", sample.upload)
                        )
                        .foregroundStyle(by: .value("Direction", "Upload"))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let speed = value.as(Int64.self) { Text(Formatters.speed(speed)) }
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 220)
                    .accessibilityLabel("Transfer speed over the last two minutes")
                }

                if !store.displayedActiveTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active Downloads")
                            .font(.headline)
                        ForEach(store.displayedActiveTasks.prefix(6)) { task in
                            DashboardTaskLine(task: task)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Bandwidth Is Quiet",
                        systemImage: "waveform.path",
                        description: Text("Start a download to see live transfer activity.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

private struct TransferSummary: View {
    let store: DownloadStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 42, verticalSpacing: 6) {
            GridRow {
                summary("Download", value: Formatters.speed(store.globalStat.downloadSpeed), image: "arrow.down")
                summary("Upload", value: Formatters.speed(store.globalStat.uploadSpeed), image: "arrow.up")
                summary("Active", value: String(store.globalStat.numActive), image: "bolt")
                summary("Waiting", value: String(store.globalStat.numWaiting), image: "clock")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func summary(_ title: String, value: String, image: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: image)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minWidth: 130, alignment: .leading)
    }
}

private struct DashboardTaskLine: View {
    let task: DownloadTask

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12) {
            GridRow {
                Text(task.name)
                    .lineLimit(1)
                    .gridColumnAlignment(.leading)
                ProgressView(value: task.progress)
                    .frame(minWidth: 180)
                Text(Formatters.percent(task.progress))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Formatters.speed(task.downloadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}
