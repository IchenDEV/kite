import Foundation
import Testing
@testable import SuperDD

@Suite("MDXP remote control")
struct MDXPTests {
    @Test("Initialization follows JSON-RPC 2.0 and MDXP 1.0")
    func initialize() async throws {
        var settings = AppSettings()
        settings.features.remote.secret = "remote-test-secret"
        let router = ExtensionRouter(
            client: Aria2RPCClient(port: 1, secret: "unused"),
            settings: settings,
            engineVersion: "2.5.5",
            authorizationSecret: "remote-test-secret",
            exposesRemoteUI: true
        )
        let request = HTTPRequest(
            method: "POST",
            path: "/mdxp",
            headers: ["authorization": "Bearer remote-test-secret"],
            body: Data(#"{"jsonrpc":"2.0","id":"test","method":"motrix/initialize","params":{}}"#.utf8)
        )
        let response = await router.response(for: request)
        #expect(response.status == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "1.0")
    }

    @Test("MDXP rejects an invalid Bearer token")
    func rejectsInvalidToken() async {
        let router = ExtensionRouter(
            client: Aria2RPCClient(port: 1, secret: "unused"),
            settings: AppSettings(),
            engineVersion: "2.5.5",
            authorizationSecret: "correct",
            exposesRemoteUI: true
        )
        let response = await router.response(for: HTTPRequest(
            method: "POST",
            path: "/mdxp",
            headers: ["authorization": "Bearer wrong"],
            body: Data()
        ))
        #expect(response.status == 401)
    }
}
