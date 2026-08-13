import Foundation

enum DownloadProtocolKind: String, CaseIterable, Sendable {
    case http
    case https
    case ftp
    case magnet
    case ed2k
    case thunder

    var title: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .ftp: "FTP"
        case .magnet: "Magnet"
        case .ed2k: "ED2K"
        case .thunder: "Thunder"
        }
    }

    var usesNetworkPreview: Bool {
        self == .http || self == .https
    }
}

struct DownloadPreview: Equatable, Identifiable, Sendable {
    var id: String { originalValue }

    let originalValue: String
    let originalURL: URL?
    let finalURL: URL?
    let protocolKind: DownloadProtocolKind
    let statusCode: Int?
    let mimeType: String?
    let contentLength: Int64?
    let suggestedFilename: String?
    let didUseRangeFallback: Bool

    var displayName: String {
        if let suggestedFilename, !suggestedFilename.isEmpty {
            return suggestedFilename
        }
        if let finalURL,
           let filename = Self.filename(from: finalURL),
           !filename.isEmpty {
            return filename
        }
        if let host, !host.isEmpty {
            return host
        }
        return "\(protocolKind.title) download"
    }

    var host: String? {
        finalURL?.host(percentEncoded: false)
            ?? originalURL?.host(percentEncoded: false)
    }

    var isReachable: Bool {
        guard protocolKind.usesNetworkPreview else { return true }
        guard let statusCode else { return false }
        return (200 ... 399).contains(statusCode)
    }

    var usesNetworkPreview: Bool { protocolKind.usesNetworkPreview }

    var statusDescription: String? {
        guard let statusCode else { return nil }
        return HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }

    private static func filename(from url: URL) -> String? {
        let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return filename.isEmpty ? nil : filename
    }
}

enum DownloadSizeSummary {
    static func total<S: Sequence>(_ values: S) -> Int64? where S.Element == Int64 {
        var result: Int64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}
