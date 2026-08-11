import Foundation

enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard
    case all
    case downloading
    case waiting
    case completed
    case failed
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .all: "All Tasks"
        case .downloading: "Downloading"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .waiting: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .history: "archivebox"
        }
    }
}
