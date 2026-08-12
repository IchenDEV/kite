import Foundation

enum DownloadURLNormalizer {
    private static let networkSchemes = Set(["http", "https", "ftp"])

    static func normalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("thunder://") {
            return decodeThunder(trimmed)
        }
        if trimmed.lowercased().hasPrefix("kite://add?")
            || trimmed.lowercased().hasPrefix("superdd://add?") {
            return URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "url" })?.value
        }
        return trimmed
    }

    static func extractMany(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .compactMap { normalizedDownloadURL(String($0)) }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedDownloadURL(_ value: String) -> String? {
        guard let normalized = normalize(value) else { return nil }
        let lowercased = normalized.lowercased()

        if lowercased.hasPrefix("ed2k://|file|") {
            return normalized
        }

        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased() else { return nil }

        if networkSchemes.contains(scheme) {
            guard let host = components.host, !host.isEmpty else { return nil }
            return normalized
        }

        if scheme == "magnet",
           components.queryItems?.contains(where: { $0.name.lowercased() == "xt" && !($0.value ?? "").isEmpty }) == true {
            return normalized
        }

        return nil
    }

    private static func decodeThunder(_ value: String) -> String? {
        let encoded = String(value.dropFirst("thunder://".count))
        guard let data = Data(base64Encoded: encoded),
              var decoded = String(data: data, encoding: .utf8) else { return nil }
        if decoded.hasPrefix("AA") { decoded.removeFirst(2) }
        if decoded.hasSuffix("ZZ") { decoded.removeLast(2) }
        return decoded
    }
}
