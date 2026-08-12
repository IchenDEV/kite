import Foundation
import Testing
@testable import Kite

@Suite("Active download summary")
struct ActiveDownloadSummaryTests {
    @Test("Progress is byte-weighted and speed is summed")
    func summarizesKnownActiveDownloads() {
        let summary = ActiveDownloadSummary(tasks: [
            task(id: "small", status: .active, completed: 50, total: 100, speed: 20),
            task(id: "large", status: .active, completed: 250, total: 900, speed: 30),
            task(id: "paused", status: .paused, completed: 100, total: 100, speed: 99),
        ])

        #expect(summary.activeCount == 2)
        #expect(summary.progress == 0.3)
        #expect(summary.downloadSpeed == 50)
    }

    @Test("Unknown task length does not present a misleading percentage")
    func handlesUnknownLength() {
        let summary = ActiveDownloadSummary(tasks: [
            task(id: "known", status: .active, completed: 50, total: 100, speed: 20),
            task(id: "metadata", status: .active, completed: 0, total: 0, speed: 10),
        ])

        #expect(summary.activeCount == 2)
        #expect(summary.progress == nil)
        #expect(summary.downloadSpeed == 30)
    }

    @Test("Idle summary has no progress or speed")
    func handlesIdleState() {
        let summary = ActiveDownloadSummary(tasks: [])

        #expect(summary.activeCount == 0)
        #expect(summary.progress == nil)
        #expect(summary.downloadSpeed == 0)
    }

    private func task(
        id: String,
        status: DownloadStatus,
        completed: Int64,
        total: Int64,
        speed: Int64
    ) -> DownloadTask {
        DownloadTask.media(
            gid: id,
            status: status,
            sourceURL: "https://example.com/\(id)",
            outputPath: "/tmp/\(id)",
            completedLength: completed,
            totalLength: total,
            downloadSpeed: speed
        )
    }
}
