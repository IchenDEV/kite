import Foundation

actor GeoIPService {
    private struct Range: Sendable {
        let start: UInt32
        let end: UInt32
        let country: String
    }

    private var source = ""
    private var ranges: [Range] = []

    func configure(source value: String) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != source else { return }
        guard !value.isEmpty else { source = ""; ranges = []; return }
        let data: Data
        if let url = URL(string: value), !url.isFileURL, url.scheme != nil {
            let (downloaded, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            data = downloaded
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: value))
        }
        let text = String(decoding: data, as: UTF8.self)
        ranges = text.split(whereSeparator: \.isNewline).compactMap { parse(String($0)) }.sorted { $0.start < $1.start }
        source = value
    }

    func country(for address: String) -> String? {
        guard let value = ipv4(address), !ranges.isEmpty else { return nil }
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if value < range.start { high = middle - 1 }
            else if value > range.end { low = middle + 1 }
            else { return range.country }
        }
        return nil
    }

    private func parse(_ line: String) -> Range? {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("#") else { return nil }
        let fields = clean.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        guard fields.count >= 2 else { return nil }
        if fields[0].contains("/") {
            let parts = fields[0].split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let address = ipv4(String(parts[0])), let bits = Int(parts[1]), (0 ... 32).contains(bits) else { return nil }
            let mask: UInt32 = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
            return Range(start: address & mask, end: (address & mask) | ~mask, country: fields[1])
        }
        guard fields.count >= 3,
              let start = UInt32(fields[0]) ?? ipv4(fields[0]),
              let end = UInt32(fields[1]) ?? ipv4(fields[1]) else { return nil }
        return Range(start: start, end: end, country: fields[2])
    }

    private func ipv4(_ value: String) -> UInt32? {
        let components = value.split(separator: ".")
        guard components.count == 4 else { return nil }
        var result: UInt32 = 0
        for component in components {
            guard let octet = UInt8(component) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }
}
