import Foundation
import Darwin

private struct ZipEntry: Sendable {
    let name: String
    let data: Data
    let date: Date
}

private struct ZipCentralRecord {
    let name: Data
    let crc32: UInt32
    let size: UInt32
    let offset: UInt32
    let dosTime: UInt16
    let dosDate: UInt16
}

private enum StoredZipWriter {
    static func archive(entries: [ZipEntry]) -> Data {
        var output = Data()
        var centralRecords: [ZipCentralRecord] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(clamping: entry.data.count)
            let timestamp = dosTimestamp(entry.date)
            let offset = UInt32(clamping: output.count)

            output.appendLittleEndian(UInt32(0x04034B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(timestamp.time)
            output.appendLittleEndian(timestamp.date)
            output.appendLittleEndian(crc)
            output.appendLittleEndian(size)
            output.appendLittleEndian(size)
            output.appendLittleEndian(UInt16(clamping: name.count))
            output.appendLittleEndian(UInt16(0))
            output.append(name)
            output.append(entry.data)

            centralRecords.append(
                ZipCentralRecord(
                    name: name,
                    crc32: crc,
                    size: size,
                    offset: offset,
                    dosTime: timestamp.time,
                    dosDate: timestamp.date
                )
            )
        }

        let centralOffset = UInt32(clamping: output.count)
        for record in centralRecords {
            output.appendLittleEndian(UInt32(0x02014B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(record.dosTime)
            output.appendLittleEndian(record.dosDate)
            output.appendLittleEndian(record.crc32)
            output.appendLittleEndian(record.size)
            output.appendLittleEndian(record.size)
            output.appendLittleEndian(UInt16(clamping: record.name.count))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(record.offset)
            output.append(record.name)
        }
        let centralSize = UInt32(clamping: output.count) - centralOffset

        output.appendLittleEndian(UInt32(0x06054B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(clamping: centralRecords.count))
        output.appendLittleEndian(UInt16(clamping: centralRecords.count))
        output.appendLittleEndian(centralSize)
        output.appendLittleEndian(centralOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let values = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((values.year ?? 1980) - 1980, 0)
        let dosDate = UInt16((year << 9) | ((values.month ?? 1) << 5) | (values.day ?? 1))
        let dosTime = UInt16(((values.hour ?? 0) << 11) | ((values.minute ?? 0) << 5) | ((values.second ?? 0) / 2))
        return (dosTime, dosDate)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

actor DiagnosticsService {
    func export(to destination: URL, settings: AppSettings, historyIntegrity: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var settingsObject = (try JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any]) ?? [:]
        settingsObject["extensionSecret"] = "<redacted>"
        settingsObject["proxyPassword"] = "<redacted>"
        let redactedSettings = try JSONSerialization.data(withJSONObject: settingsObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        let report: [String: Any] = [
            "appVersion": "0.1.0",
            "generatedAt": ISO8601DateFormatter().string(from: .now),
            "historyIntegrity": historyIntegrity,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": ProcessInfo.processInfo.machineArchitecture,
            "swiftRuntime": "Swift 6",
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])

        var entries = [
            ZipEntry(name: "report.json", data: reportData, date: .now),
            ZipEntry(name: "settings-redacted.json", data: redactedSettings, date: .now),
        ]
        if let logURL = supportDirectory?.appending(path: "aria2-next.log"),
           let logData = try? Data(contentsOf: logURL) {
            entries.append(ZipEntry(name: "aria2-next.log", data: Data(logData.suffix(2_000_000)), date: .now))
        }
        let archive = StoredZipWriter.archive(entries: entries)
        try archive.write(to: destination, options: .atomic)
    }

    private var supportDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "SuperDD", directoryHint: .isDirectory)
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
