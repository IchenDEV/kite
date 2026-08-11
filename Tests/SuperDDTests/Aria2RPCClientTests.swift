import Foundation
import Testing
@testable import SuperDD

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("aria2 JSON-RPC client", .serialized)
struct Aria2RPCClientTests {
    @Test("RPC calls authenticate with the token prefix")
    func authentication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            let body = try #require(requestBody(request))
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["method"] as? String == "aria2.getGlobalStat")
            let params = try #require(object["params"] as? [Any])
            #expect(params.first as? String == "token:test-secret")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"jsonrpc":"2.0","id":"1","result":{"downloadSpeed":"12","uploadSpeed":"3","numActive":"1","numWaiting":"0","numStopped":"2"}}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = Aria2RPCClient(port: 29_100, secret: "test-secret", session: session)
        let stat = try await client.globalStat()
        #expect(stat.downloadSpeed == 12)
        #expect(stat.uploadSpeed == 3)
        #expect(stat.numActive == 1)
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
