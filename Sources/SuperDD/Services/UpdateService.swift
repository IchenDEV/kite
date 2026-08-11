import CryptoKit
import Darwin
import Foundation

struct ReleaseAsset: Codable, Identifiable, Sendable {
    var id: String { downloadURL.absoluteString }
    let name: String
    let downloadURL: URL
    let size: Int64
}

struct AvailableUpdate: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let releaseNotes: String
    let webURL: URL
    let assets: [ReleaseAsset]
}

enum UpdateServiceError: LocalizedError, Sendable {
    case invalidFeed
    case noCompatibleAsset
    case checksumMissing
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "The update feed returned an invalid release."
        case .noCompatibleAsset: "This release has no compatible macOS ZIP or DMG."
        case .checksumMissing: "The release does not include a SHA-256 checksum file."
        case .checksumMismatch: "The downloaded update failed SHA-256 verification."
        }
    }
}

actor UpdateService {
    func check(feedURL: String, currentVersion: String) async throws -> AvailableUpdate? {
        guard let url = URL(string: feedURL) else { throw UpdateServiceError.invalidFeed }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SuperDD/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let web = object["html_url"] as? String, let webURL = URL(string: web) else {
            throw UpdateServiceError.invalidFeed
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard version.compare(currentVersion, options: .numeric) == .orderedDescending else { return nil }
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> ReleaseAsset? in
            guard let name = asset["name"] as? String,
                  let value = asset["browser_download_url"] as? String,
                  let url = URL(string: value) else { return nil }
            return ReleaseAsset(name: name, downloadURL: url, size: Int64(asset["size"] as? Int ?? 0))
        }
        return AvailableUpdate(
            version: version,
            releaseNotes: object["body"] as? String ?? "",
            webURL: webURL,
            assets: assets
        )
    }

    func download(_ update: AvailableUpdate, requireChecksum: Bool = true) async throws -> URL {
        let architecture = ProcessInfo.processInfo.machineArchitecture
        let packages = update.assets.filter {
            let value = $0.name.lowercased()
            return value.hasSuffix(".dmg") || value.hasSuffix(".zip")
        }
        let asset = packages.first(where: { $0.name.lowercased().contains(architecture) }) ?? packages.first
        guard let asset else { throw UpdateServiceError.noCompatibleAsset }
        let (temporaryURL, response) = try await URLSession.shared.download(from: asset.downloadURL)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let checksumAsset = update.assets.first {
            let lower = $0.name.lowercased()
            return lower == "sha256sums.txt" || lower == "checksums.txt" || lower.hasSuffix(".sha256")
        }
        if let checksumAsset {
            let (data, _) = try await URLSession.shared.data(from: checksumAsset.downloadURL)
            let checksums = String(decoding: data, as: UTF8.self)
            guard let expected = checksum(for: asset.name, in: checksums) else { throw UpdateServiceError.checksumMissing }
            let actual = try sha256(temporaryURL)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw UpdateServiceError.checksumMismatch }
        } else if requireChecksum {
            throw UpdateServiceError.checksumMissing
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = downloads.appending(path: asset.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func checksum(for filename: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let values = line.split(whereSeparator: \.isWhitespace)
            guard let hash = values.first, hash.count == 64 else { continue }
            if values.count == 1 || values.dropFirst().contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename }) {
                return String(hash)
            }
        }
        return nil
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
