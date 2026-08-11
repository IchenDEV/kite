import Foundation

enum DownloadURLNormalizer {
    static func normalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("thunder://") {
            return decodeThunder(trimmed)
        }
        if trimmed.lowercased().hasPrefix("superdd://add?") {
            return URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "url" })?.value
        }
        return trimmed
    }

    static func extractMany(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { normalize(String($0)) }
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
