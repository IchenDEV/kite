import Foundation
import Testing
@testable import Kite

private final class DownloadPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Download preview service", .serialized)
struct DownloadPreviewServiceTests {
    @Test("HEAD metadata and final redirect URL produce a preview")
    func headPreview() async throws {
        let session = makeSession()
        DownloadPreviewURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "HEAD")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "KiteTests/1")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://origin.example/")
            let finalURL = try #require(URL(string: "https://cdn.example/releases/Kite.zip"))
            let response = try #require(HTTPURLResponse(
                url: finalURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/zip; charset=binary",
                    "Content-Length": "4096",
                ]
            ))
            return (response, Data())
        }
        defer { DownloadPreviewURLProtocol.requestHandler = nil }

        let preview = try await DownloadPreviewService(session: session).preview(
            "https://example.com/download/latest",
            headers: [
                "User-Agent": "KiteTests/1",
                "Referer": "https://origin.example/",
            ]
        )

        #expect(preview.protocolKind == .https)
        #expect(preview.finalURL?.absoluteString == "https://cdn.example/releases/Kite.zip")
        #expect(preview.statusCode == 200)
        #expect(preview.mimeType == "application/zip")
        #expect(preview.contentLength == 4_096)
        #expect(preview.displayName == "Kite.zip")
        #expect(preview.host == "cdn.example")
        #expect(preview.isReachable)
        #expect(!preview.didUseRangeFallback)
    }

    @Test("HEAD rejection falls back to a one-byte Range GET")
    func headRejectionUsesRange() async throws {
        let session = makeSession()
        var requestCount = 0
        DownloadPreviewURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.httpMethod == "HEAD")
                return (
                    try #require(HTTPURLResponse(
                        url: request.url!,
                        statusCode: 405,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )),
                    Data()
                )
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=test")
            return (
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/octet-stream",
                        "Content-Length": "1",
                        "Content-Range": "bytes 0-0/987654321",
                        "Content-Disposition": "attachment; filename=archive.bin",
                    ]
                )),
                Data([0])
            )
        }
        defer { DownloadPreviewURLProtocol.requestHandler = nil }

        let preview = try await DownloadPreviewService(session: session).preview(
            "https://downloads.example/item",
            headers: ["Cookie": "session=test"]
        )

        #expect(requestCount == 2)
        #expect(preview.statusCode == 206)
        #expect(preview.contentLength == 987_654_321)
        #expect(preview.suggestedFilename == "archive.bin")
        #expect(preview.didUseRangeFallback)
        #expect(preview.isReachable)
    }

    @Test("Missing HEAD metadata falls back and prefers RFC 5987 filename")
    func metadataFallbackAndExtendedFilename() async throws {
        let session = makeSession()
        var requestCount = 0
        DownloadPreviewURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.httpMethod == "HEAD" {
                return (
                    try #require(HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["ETag": "test"]
                    )),
                    Data()
                )
            }
            return (
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Range": "bytes 0-0/42",
                        "Content-Disposition": "attachment; filename=resume.pdf; filename*=UTF-8''r%C3%A9sum%C3%A9%202026.pdf",
                    ]
                )),
                Data([0])
            )
        }
        defer { DownloadPreviewURLProtocol.requestHandler = nil }

        let preview = try await DownloadPreviewService(session: session).preview("https://example.com/file")

        #expect(requestCount == 2)
        #expect(preview.suggestedFilename == "résumé 2026.pdf")
        #expect(preview.contentLength == 42)
        #expect(preview.didUseRangeFallback)
    }

    @Test("Timeouts become a friendly preview error")
    func timeoutError() async throws {
        let session = makeSession()
        DownloadPreviewURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
        defer { DownloadPreviewURLProtocol.requestHandler = nil }

        do {
            _ = try await DownloadPreviewService(session: session).preview("https://example.com/file")
            Issue.record("Expected the preview request to time out")
        } catch let error as DownloadPreviewError {
            #expect(error == .timedOut)
            #expect(error.localizedDescription.contains("timed out"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Non-HTTP protocols are parsed without network access")
    func nonHTTPPreviews() async throws {
        let session = makeSession()
        DownloadPreviewURLProtocol.requestHandler = { _ in
            Issue.record("Non-HTTP previews must not make a network request")
            throw URLError(.badURL)
        }
        defer { DownloadPreviewURLProtocol.requestHandler = nil }
        let service = DownloadPreviewService(session: session)

        let ftp = try await service.preview("ftp://mirror.example/pub/archive.tar.xz")
        #expect(ftp.protocolKind == .ftp)
        #expect(ftp.displayName == "archive.tar.xz")
        #expect(ftp.host == "mirror.example")
        #expect(ftp.isReachable)
        #expect(!ftp.usesNetworkPreview)

        let magnet = try await service.preview("magnet:?xt=urn:btih:0123456789&dn=Kite%20Source&xl=2048")
        #expect(magnet.protocolKind == .magnet)
        #expect(magnet.displayName == "Kite Source")
        #expect(magnet.contentLength == 2_048)
        #expect(magnet.isReachable)

        let ed2k = try await service.preview("ed2k://|file|Kite%20Archive.zip|8192|ABCDEF|/")
        #expect(ed2k.protocolKind == .ed2k)
        #expect(ed2k.displayName == "Kite Archive.zip")
        #expect(ed2k.contentLength == 8_192)
        #expect(ed2k.originalURL == nil)
        #expect(ed2k.isReachable)
    }

    @Test("Invalid and unsupported links report actionable errors")
    func validationErrors() async {
        let service = DownloadPreviewService(session: makeSession())

        do {
            _ = try await service.preview("not a URL")
            Issue.record("Expected an invalid URL error")
        } catch let error as DownloadPreviewError {
            #expect(error == .invalidURL)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await service.preview("file:///tmp/archive.zip")
            Issue.record("Expected an unsupported protocol error")
        } catch let error as DownloadPreviewError {
            #expect(error == .unsupportedProtocol("file"))
            #expect(error.localizedDescription.contains("FILE"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Byte totals reject negative values and integer overflow")
    func byteTotalValidation() {
        #expect(DownloadSizeSummary.total([1, 2, 3]) == 6)
        #expect(DownloadSizeSummary.total([Int64.max, 1]) == nil)
        #expect(DownloadSizeSummary.total([1, -1]) == nil)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadPreviewURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
