import Foundation
import Network
import OSLog

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let body: Data
    var headers: [String: String] = [:]

    static func json(status: Int = 200, reason: String = "OK", _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason, body: body, headers: ["Content-Type": "application/json; charset=utf-8"])
    }
}

private struct ExtensionAddRequest: Decodable {
    struct Header: Decodable {
        let name: String
        let value: String
    }

    let url: String
    let finalUrl: String?
    let referer: String?
    let cookie: String?
    let userAgent: String?
    let requestHeaders: [Header]?
    let filename: String?
}

private actor ExtensionRouter {
    let client: Aria2RPCClient
    let settings: AppSettings
    let engineVersion: String

    init(client: Aria2RPCClient, settings: AppSettings, engineVersion: String) {
        self.client = client
        self.settings = settings
        self.engineVersion = engineVersion
    }

    func response(for request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return withCORS(.json(["status": "ok"]), request: request)
        }

        let response: HTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            response = .json(["status": "ok", "version": "0.1.0"])
        case ("GET", "/version"):
            response = .json(["app": "0.1.0", "engine": engineVersion])
        case ("GET", "/stat"):
            guard isAuthorized(request) else { return withCORS(unauthorized, request: request) }
            do {
                let stat = try await client.globalStat()
                response = .json([
                    "downloadSpeed": String(stat.downloadSpeed),
                    "uploadSpeed": String(stat.uploadSpeed),
                    "numActive": String(stat.numActive),
                    "numWaiting": String(stat.numWaiting),
                    "numStopped": String(stat.numStopped),
                    "numStoppedTotal": String(stat.numStopped),
                ])
            } catch {
                response = serverError(error)
            }
        case ("POST", "/add"):
            guard isAuthorized(request) else { return withCORS(unauthorized, request: request) }
            response = await add(request)
        case ("POST", "/pause-all"):
            guard isAuthorized(request) else { return withCORS(unauthorized, request: request) }
            do {
                _ = try await client.call("aria2.forcePauseAll")
                response = .json(["status": "ok"])
            } catch {
                response = serverError(error)
            }
        case ("POST", "/resume-all"):
            guard isAuthorized(request) else { return withCORS(unauthorized, request: request) }
            do {
                let waiting = try await client.tellWaiting()
                for task in waiting where task.status == .paused { try await client.resume(gid: task.gid) }
                response = .json(["status": "ok"])
            } catch {
                response = serverError(error)
            }
        case ("GET", "/tasks"):
            guard isAuthorized(request) else { return withCORS(unauthorized, request: request) }
            do {
                async let active = client.tellActive()
                async let waiting = client.tellWaiting()
                async let stopped = client.tellStopped()
                let values = try await (active, waiting, stopped)
                let tasks = values.0 + values.1 + values.2
                response = .json(["tasks": tasks.map(taskObject)])
            } catch {
                response = serverError(error)
            }
        default:
            response = .json(status: 404, reason: "Not Found", ["error": "not_found"])
        }
        return withCORS(response, request: request)
    }

    private func add(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let body = try JSONDecoder().decode(ExtensionAddRequest.self, from: request.body)
            let sourceURL = body.finalUrl.flatMap { $0.isEmpty ? nil : $0 } ?? body.url
            guard let normalizedURL = DownloadURLNormalizer.normalize(sourceURL) else {
                return .json(status: 400, reason: "Bad Request", ["error": "invalid_url"])
            }

            var options: [String: JSONValue] = [
                "dir": .string(settings.downloadDirectory),
                "user-agent": .string(body.userAgent ?? settings.userAgent),
            ]
            if let filename = body.filename, !filename.isEmpty { options["out"] = .string(filename) }
            if let referer = body.referer, !referer.isEmpty { options["referer"] = .string(referer) }
            var headers = body.requestHeaders?.map { JSONValue.string("\($0.name): \($0.value)") } ?? []
            if let cookie = body.cookie, !cookie.isEmpty { headers.append(.string("Cookie: \(cookie)")) }
            if !headers.isEmpty { options["header"] = .array(headers) }

            let gid = try await client.addURI(normalizedURL, options: options)
            return .json(["action": "submitted", "gid": gid])
        } catch let error as DecodingError {
            return .json(status: 400, reason: "Bad Request", ["error": "invalid_json", "message": String(describing: error)])
        } catch {
            return serverError(error)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        settings.extensionSecret.isEmpty
            || request.headers["authorization"] == "Bearer \(settings.extensionSecret)"
    }

    private var unauthorized: HTTPResponse {
        .json(status: 401, reason: "Unauthorized", ["error": "unauthorized"])
    }

    private func serverError(_ error: Error) -> HTTPResponse {
        .json(status: 500, reason: "Internal Server Error", ["status": "error", "error": error.localizedDescription])
    }

    private func taskObject(_ task: DownloadTask) -> [String: Any] {
        [
            "gid": task.gid,
            "name": task.name,
            "status": task.status.rawValue,
            "totalLength": String(task.totalLength),
            "completedLength": String(task.completedLength),
            "downloadSpeed": String(task.downloadSpeed),
            "uploadSpeed": String(task.uploadSpeed),
        ]
    }

    private func withCORS(_ response: HTTPResponse, request: HTTPRequest) -> HTTPResponse {
        var headers = response.headers
        let origin = request.headers["origin"] ?? "null"
        if origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://") || origin == "null" {
            headers["Access-Control-Allow-Origin"] = origin
        }
        headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
        headers["Access-Control-Allow-Private-Network"] = "true"
        return HTTPResponse(status: response.status, reason: response.reason, body: response.body, headers: headers)
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let router: ExtensionRouter
    private var buffer = Data()

    init(connection: NWConnection, router: ExtensionRouter) {
        self.connection = connection
        self.router = router
    }

    func start() {
        connection.start(queue: .global(qos: .utility))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if let request = self.parseRequest() {
                Task {
                    let response = await self.router.response(for: request)
                    self.send(response)
                }
            } else if error == nil, !isComplete {
                self.receive()
            } else {
                self.connection.cancel()
            }
        }
    }

    private func parseRequest() -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator),
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestParts = first.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart ..< bodyStart + contentLength)
        let rawPath = String(requestParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return HTTPRequest(method: String(requestParts[0]).uppercased(), path: path, headers: headers, body: body)
    }

    private func send(_ response: HTTPResponse) {
        var headerLines = [
            "HTTP/1.1 \(response.status) \(response.reason)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
        ]
        headerLines.append(contentsOf: response.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
        var data = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

actor ExtensionServer {
    private var listener: NWListener?
    private let logger = Logger(subsystem: "com.chenli.superdd", category: "extension-api")

    func start(preferredPort: Int, settings: AppSettings, client: Aria2RPCClient, engineVersion: String) throws -> Int {
        listener?.cancel()
        let portNumber = try LocalPortResolver.available(startingAt: preferredPort)
        guard let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            throw Aria2RPCError(code: -1, message: "Invalid extension API port \(portNumber)")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        let router = ExtensionRouter(client: client, settings: settings, engineVersion: engineVersion)
        listener.newConnectionHandler = { connection in
            HTTPConnection(connection: connection, router: router).start()
        }
        listener.stateUpdateHandler = { [logger] state in
            if case let .failed(error) = state { logger.error("Extension API failed: \(error.localizedDescription)") }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info("Extension API listening on 127.0.0.1:\(portNumber)")
        return portNumber
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
