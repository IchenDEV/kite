import Foundation

struct Aria2RPCError: LocalizedError, Sendable {
    let code: Int
    let message: String

    var errorDescription: String? { "aria2 RPC error \(code): \(message)" }
}

private struct RPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: [JSONValue]
}

private struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

private struct RPCResponse: Decodable {
    let result: JSONValue?
    let error: RPCErrorPayload?
}

actor Aria2RPCClient {
    private let endpoint: URL
    private let secret: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(port: Int, secret: String, session: URLSession = .shared) {
        endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
        self.secret = secret
        self.session = session
    }

    func call(_ method: String, params: [JSONValue] = []) async throws -> JSONValue {
        let requestPayload = RPCRequest(
            id: UUID().uuidString,
            method: method,
            params: [.string("token:\(secret)")] + params
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try encoder.encode(requestPayload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let payload = try decoder.decode(RPCResponse.self, from: data)
        if let error = payload.error {
            throw Aria2RPCError(code: error.code, message: error.message)
        }
        return payload.result ?? .null
    }

    func addURI(_ uri: String, options: [String: JSONValue], position: Int? = nil) async throws -> String {
        var params: [JSONValue] = [.array([.string(uri)]), .object(options)]
        if let position { params.append(.number(Double(position))) }
        let result = try await call("aria2.addUri", params: params)
        guard let gid = result.stringValue else { throw Aria2RPCError(code: -1, message: "aria2.addUri returned no GID") }
        return gid
    }

    func addTorrent(data: Data, options: [String: JSONValue], position: Int? = nil) async throws -> String {
        let encoded = data.base64EncodedString()
        var params: [JSONValue] = [.string(encoded), .array([]), .object(options)]
        if let position { params.append(.number(Double(position))) }
        let result = try await call("aria2.addTorrent", params: params)
        guard let gid = result.stringValue else { throw Aria2RPCError(code: -1, message: "aria2.addTorrent returned no GID") }
        return gid
    }

    func addMetalink(data: Data, options: [String: JSONValue], position: Int? = nil) async throws -> [String] {
        var params: [JSONValue] = [.string(data.base64EncodedString()), .object(options)]
        if let position { params.append(.number(Double(position))) }
        let result = try await call("aria2.addMetalink", params: params)
        return result.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func tellActive() async throws -> [DownloadTask] {
        decodeTasks(try await call("aria2.tellActive", params: [.array(Self.taskKeys)]))
    }

    func tellWaiting(offset: Int = 0, count: Int = 1_000) async throws -> [DownloadTask] {
        decodeTasks(try await call("aria2.tellWaiting", params: [.number(Double(offset)), .number(Double(count)), .array(Self.taskKeys)]))
    }

    func tellStopped(offset: Int = 0, count: Int = 1_000) async throws -> [DownloadTask] {
        decodeTasks(try await call("aria2.tellStopped", params: [.number(Double(offset)), .number(Double(count)), .array(Self.taskKeys)]))
    }

    func tellStatus(gid: String) async throws -> DownloadTask {
        let value = try await call("aria2.tellStatus", params: [.string(gid), .array(Self.taskKeys)])
        guard let object = value.objectValue else { throw Aria2RPCError(code: -1, message: "Malformed task response") }
        return DownloadTask(json: object)
    }

    func globalStat() async throws -> GlobalStat {
        let value = try await call("aria2.getGlobalStat")
        return GlobalStat(json: value.objectValue ?? [:])
    }

    func pause(gid: String, force: Bool = false) async throws {
        _ = try await call(force ? "aria2.forcePause" : "aria2.pause", params: [.string(gid)])
    }

    func resume(gid: String) async throws {
        _ = try await call("aria2.unpause", params: [.string(gid)])
    }

    func remove(gid: String, force: Bool = false) async throws {
        _ = try await call(force ? "aria2.forceRemove" : "aria2.remove", params: [.string(gid)])
    }

    func removeResult(gid: String) async throws {
        _ = try await call("aria2.removeDownloadResult", params: [.string(gid)])
    }

    func changeOption(gid: String, options: [String: JSONValue]) async throws {
        _ = try await call("aria2.changeOption", params: [.string(gid), .object(options)])
    }

    func changeGlobalOption(_ options: [String: JSONValue]) async throws {
        _ = try await call("aria2.changeGlobalOption", params: [.object(options)])
    }

    func options(gid: String) async throws -> [String: JSONValue] {
        let value = try await call("aria2.getOption", params: [.string(gid)])
        return value.objectValue ?? [:]
    }

    @discardableResult
    func changePosition(gid: String, position: Int, how: String = "POS_SET") async throws -> Int {
        let result = try await call(
            "aria2.changePosition",
            params: [.string(gid), .number(Double(position)), .string(how)]
        )
        return Int(result.int64Value ?? 0)
    }

    func pauseAll() async throws {
        _ = try await call("aria2.forcePauseAll")
    }

    func resumeAll() async throws {
        _ = try await call("aria2.unpauseAll")
    }

    func peers(gid: String) async throws -> [Peer] {
        let result = try await call("aria2.getPeers", params: [.string(gid)])
        return result.arrayValue?.compactMap(\.objectValue).map(Peer.init) ?? []
    }

    func saveSession() async throws {
        _ = try await call("aria2.saveSession")
    }

    func shutdown(force: Bool = false) async throws {
        _ = try await call(force ? "aria2.forceShutdown" : "aria2.shutdown")
    }

    private func decodeTasks(_ value: JSONValue) -> [DownloadTask] {
        return value.arrayValue?.compactMap(\.objectValue).map(DownloadTask.init) ?? []
    }

    private static let taskKeys: [JSONValue] = [
        "gid", "status", "totalLength", "completedLength", "uploadLength",
        "downloadSpeed", "uploadSpeed", "connections", "errorCode", "errorMessage",
        "dir", "files", "bittorrent", "infoHash", "numSeeders", "seeder",
        "pieceLength", "numPieces", "bitfield", "followedBy",
    ].map(JSONValue.string)
}
