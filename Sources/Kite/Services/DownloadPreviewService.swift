import Foundation

enum DownloadPreviewError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case invalidURL
    case unsupportedProtocol(String)
    case timedOut
    case offline
    case cannotReachHost(String?)
    case secureConnectionFailed
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter a download link to preview it."
        case .invalidURL:
            "This download link is not valid."
        case let .unsupportedProtocol(value):
            "Kite cannot preview \(value.uppercased()) links."
        case .timedOut:
            "The preview request timed out. Check the connection and try again."
        case .offline:
            "Kite is offline. Connect to the internet and try again."
        case let .cannotReachHost(host):
            if let host, !host.isEmpty {
                "Kite could not reach \(host)."
            } else {
                "Kite could not reach the download server."
            }
        case .secureConnectionFailed:
            "Kite could not establish a secure connection to the download server."
        case .invalidResponse:
            "The download server returned an invalid response."
        case let .requestFailed(message):
            "Kite could not preview this download: \(message)"
        }
    }
}

actor DownloadPreviewService {
    private struct ResponseMetadata {
        let mimeType: String?
        let contentLength: Int64?
        let suggestedFilename: String?
        let hasKeyMetadata: Bool
    }

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 12) {
        self.session = session
        self.timeout = max(timeout, 1)
    }

    func preview(
        _ rawValue: String,
        headers: [String: String] = [:]
    ) async throws -> DownloadPreview {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DownloadPreviewError.emptyInput }
        guard let scheme = Self.scheme(in: value) else { throw DownloadPreviewError.invalidURL }

        switch scheme {
        case "http", "https":
            return try await previewHTTP(value, scheme: scheme, headers: headers)
        case "ftp":
            return try Self.previewFTP(value)
        case "magnet":
            return try Self.previewMagnet(value)
        case "ed2k":
            return try Self.previewED2K(value)
        case "thunder":
            return try Self.previewThunder(value)
        default:
            throw DownloadPreviewError.unsupportedProtocol(scheme)
        }
    }

    private func previewHTTP(
        _ value: String,
        scheme: String,
        headers: [String: String]
    ) async throws -> DownloadPreview {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.isEmpty == false else {
            throw DownloadPreviewError.invalidURL
        }

        let headResponse = try await response(
            for: request(url: url, method: "HEAD", headers: headers)
        )
        let headMetadata = Self.metadata(from: headResponse, isRangeResponse: false)
        let shouldUseRange = headResponse.statusCode == 405
            || headResponse.statusCode == 501
            || !headMetadata.hasKeyMetadata

        guard shouldUseRange else {
            return Self.httpPreview(
                originalValue: value,
                originalURL: url,
                response: headResponse,
                metadata: headMetadata,
                protocolKind: scheme == "https" ? .https : .http,
                didUseRangeFallback: false
            )
        }

        var rangeRequest = request(url: url, method: "GET", headers: headers)
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let rangeResponse = try await response(for: rangeRequest)
        let rangeMetadata = Self.metadata(from: rangeResponse, isRangeResponse: true)
        let mergedMetadata = ResponseMetadata(
            mimeType: rangeMetadata.mimeType ?? headMetadata.mimeType,
            contentLength: rangeMetadata.contentLength ?? headMetadata.contentLength,
            suggestedFilename: rangeMetadata.suggestedFilename ?? headMetadata.suggestedFilename,
            hasKeyMetadata: rangeMetadata.hasKeyMetadata || headMetadata.hasKeyMetadata
        )
        return Self.httpPreview(
            originalValue: value,
            originalURL: url,
            response: rangeResponse,
            metadata: mergedMetadata,
            protocolKind: scheme == "https" ? .https : .http,
            didUseRangeFallback: true
        )
    }

    private func request(
        url: URL,
        method: String,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: trimmedName)
        }
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        return request
    }

    private func response(for request: URLRequest) async throws -> HTTPURLResponse {
        do {
            // Only the response headers are needed. Explicitly cancel the data task
            // so a server that ignores Range cannot turn preview into a full download.
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let response = response as? HTTPURLResponse else {
                throw DownloadPreviewError.invalidResponse
            }
            return response
        } catch let error as DownloadPreviewError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            throw Self.previewError(from: error, host: request.url?.host(percentEncoded: false))
        } catch {
            throw DownloadPreviewError.requestFailed(error.localizedDescription)
        }
    }

    private static func httpPreview(
        originalValue: String,
        originalURL: URL,
        response: HTTPURLResponse,
        metadata: ResponseMetadata,
        protocolKind: DownloadProtocolKind,
        didUseRangeFallback: Bool
    ) -> DownloadPreview {
        let finalURL = response.url ?? originalURL
        return DownloadPreview(
            originalValue: originalValue,
            originalURL: originalURL,
            finalURL: finalURL,
            protocolKind: protocolKind,
            statusCode: response.statusCode,
            mimeType: metadata.mimeType,
            contentLength: metadata.contentLength,
            suggestedFilename: metadata.suggestedFilename ?? safeFilename(finalURL.lastPathComponent.removingPercentEncoding),
            didUseRangeFallback: didUseRangeFallback
        )
    }

    private static func metadata(
        from response: HTTPURLResponse,
        isRangeResponse: Bool
    ) -> ResponseMetadata {
        let contentTypeHeader = nonempty(response.value(forHTTPHeaderField: "Content-Type"))
        let mimeType = contentTypeHeader
            .map { $0.split(separator: ";", maxSplits: 1).first.map(String.init) ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(nonempty)
            ?? nonempty(response.mimeType)?.lowercased()
        let disposition = nonempty(response.value(forHTTPHeaderField: "Content-Disposition"))
        let contentRange = nonempty(response.value(forHTTPHeaderField: "Content-Range"))
        let explicitContentLength = nonempty(response.value(forHTTPHeaderField: "Content-Length"))
            .flatMap(parseNonnegativeInt64)
        let rangeTotal = contentRange.flatMap(contentRangeTotal)
        let contentLength: Int64?
        if let rangeTotal {
            contentLength = rangeTotal
        } else if isRangeResponse, response.statusCode == 206 {
            // A partial response's Content-Length is the size of the returned slice,
            // not the size of the download. Without Content-Range the total is unknown.
            contentLength = nil
        } else {
            contentLength = explicitContentLength
        }
        let suggestedFilename = disposition.flatMap(contentDispositionFilename)
        return ResponseMetadata(
            mimeType: mimeType,
            contentLength: contentLength,
            suggestedFilename: suggestedFilename,
            hasKeyMetadata: contentTypeHeader != nil
                || disposition != nil
                || explicitContentLength != nil
                || rangeTotal != nil
        )
    }

    private static func previewFTP(_ value: String) throws -> DownloadPreview {
        guard let url = URL(string: value), url.host(percentEncoded: false)?.isEmpty == false else {
            throw DownloadPreviewError.invalidURL
        }
        return nonHTTPPreview(
            value,
            url: url,
            kind: .ftp,
            suggestedFilename: safeFilename(url.lastPathComponent.removingPercentEncoding),
            contentLength: nil
        )
    }

    private static func previewMagnet(_ value: String) throws -> DownloadPreview {
        guard let components = URLComponents(string: value),
              components.queryItems?.contains(where: {
                  $0.name.caseInsensitiveCompare("xt") == .orderedSame && nonempty($0.value) != nil
              }) == true else {
            throw DownloadPreviewError.invalidURL
        }
        let name = components.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare("dn") == .orderedSame
        })?.value
        let length = components.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare("xl") == .orderedSame
        })?.value.flatMap(parseNonnegativeInt64)
        return nonHTTPPreview(
            value,
            url: components.url,
            kind: .magnet,
            suggestedFilename: safeFilename(name),
            contentLength: length
        )
    }

    private static func previewED2K(_ value: String) throws -> DownloadPreview {
        let fields = value.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 6,
              fields[1].caseInsensitiveCompare("file") == .orderedSame,
              !fields[2].isEmpty,
              parseNonnegativeInt64(String(fields[3])) != nil else {
            throw DownloadPreviewError.invalidURL
        }
        return nonHTTPPreview(
            value,
            url: nil,
            kind: .ed2k,
            suggestedFilename: safeFilename(String(fields[2]).removingPercentEncoding ?? String(fields[2])),
            contentLength: parseNonnegativeInt64(String(fields[3]))
        )
    }

    private static func previewThunder(_ value: String) throws -> DownloadPreview {
        guard let url = URL(string: value),
              let decoded = DownloadURLNormalizer.normalize(value),
              decoded != value else {
            throw DownloadPreviewError.invalidURL
        }
        return nonHTTPPreview(
            value,
            url: url,
            kind: .thunder,
            suggestedFilename: filenameFromDownloadValue(decoded),
            contentLength: nil
        )
    }

    private static func nonHTTPPreview(
        _ value: String,
        url: URL?,
        kind: DownloadProtocolKind,
        suggestedFilename: String?,
        contentLength: Int64?
    ) -> DownloadPreview {
        DownloadPreview(
            originalValue: value,
            originalURL: url,
            finalURL: url,
            protocolKind: kind,
            statusCode: nil,
            mimeType: nil,
            contentLength: contentLength,
            suggestedFilename: suggestedFilename,
            didUseRangeFallback: false
        )
    }

    private static func filenameFromDownloadValue(_ value: String) -> String? {
        if value.lowercased().hasPrefix("ed2k://|file|") {
            let fields = value.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count > 2 else { return nil }
            return safeFilename(String(fields[2]).removingPercentEncoding ?? String(fields[2]))
        }
        guard let url = URL(string: value) else { return nil }
        return safeFilename(url.lastPathComponent.removingPercentEncoding)
    }

    private static func scheme(in value: String) -> String? {
        guard let separator = value.firstIndex(of: ":"), separator != value.startIndex else { return nil }
        let scheme = String(value[..<separator]).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-")
        guard scheme.unicodeScalars.allSatisfy(allowed.contains),
              scheme.first?.isLetter == true else { return nil }
        return scheme
    }

    private static func previewError(from error: URLError, host: String?) -> DownloadPreviewError {
        switch error.code {
        case .timedOut:
            .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
            .offline
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .cannotReachHost(host)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            .secureConnectionFailed
        case .badServerResponse, .cannotParseResponse:
            .invalidResponse
        default:
            .requestFailed(error.localizedDescription)
        }
    }

    private static func contentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard total != "*" else { return nil }
        return parseNonnegativeInt64(total)
    }

    private static func contentDispositionFilename(_ value: String) -> String? {
        var filename: String?
        var extendedFilename: String?
        for field in splitHeaderParameters(value).dropFirst() {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = field[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = field[field.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "filename*":
                extendedFilename = decodeRFC5987(rawValue).flatMap(safeFilename)
            case "filename":
                filename = safeFilename(unquote(rawValue))
            default:
                continue
            }
        }
        return extendedFilename ?? filename
    }

    private static func splitHeaderParameters(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\", isQuoted {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                current.append(character)
                isQuoted.toggle()
            } else if character == ";", !isQuoted {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private static func decodeRFC5987(_ rawValue: String) -> String? {
        let unquoted = unquote(rawValue)
        let fields = unquoted.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let data = percentDecodedData(String(fields[2])) else { return nil }
        switch fields[0].lowercased() {
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "latin1":
            return String(data: data, encoding: .isoLatin1)
        case "us-ascii", "ascii":
            return String(data: data, encoding: .ascii)
        default:
            return String(data: data, encoding: .utf8)
        }
    }

    private static func percentDecodedData(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else { return nil }
                result.append((high << 4) | low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        var result = ""
        var isEscaped = false
        for character in value.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped { result.append("\\") }
        return result
    }

    private static func safeFilename(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutControls = value.components(separatedBy: .controlCharacters).joined()
        let normalizedSeparators = withoutControls.replacingOccurrences(of: "\\", with: "/")
        let filename = normalizedSeparators.split(separator: "/", omittingEmptySubsequences: true).last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let filename, !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        return filename
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseNonnegativeInt64<S: StringProtocol>(_ value: S) -> Int64? {
        guard let parsed = Int64(value), parsed >= 0 else { return nil }
        return parsed
    }
}
