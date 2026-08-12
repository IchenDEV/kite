import Foundation

struct ActiveDownloadSummary: Equatable, Sendable {
    let activeCount: Int
    let progress: Double?
    let downloadSpeed: Int64

    init(tasks: [DownloadTask]) {
        let activeTasks = tasks.filter { $0.status == .active }
        activeCount = activeTasks.count
        downloadSpeed = Self.saturatingSum(activeTasks.map(\.downloadSpeed))

        guard !activeTasks.isEmpty,
              activeTasks.allSatisfy({ $0.totalLength > 0 }) else {
            progress = nil
            return
        }

        let totalLength = activeTasks.reduce(0.0) { result, task in
            result + Double(task.totalLength)
        }
        let completedLength = activeTasks.reduce(0.0) { result, task in
            result + Double(min(max(task.completedLength, 0), task.totalLength))
        }
        progress = totalLength > 0 ? min(max(completedLength / totalLength, 0), 1) : nil
    }

    private static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(max(value, 0))
            return overflow ? .max : sum
        }
    }
}
