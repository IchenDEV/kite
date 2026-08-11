import Foundation

enum Formatters {
    static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }

    static func speed(_ value: Int64) -> String {
        "\(byteCount(value))/s"
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval >= 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "—"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
