import Foundation
import Network
import OSLog

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let body: Data
    var headers: [String: String] = [:]

    static func json(status: Int = 200, reason: String = "OK", _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason, body: body, headers: ["Content-Type": "application/json; charset=utf-8"])
    }

    static func html(_ value: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            reason: "OK",
            body: Data(value.utf8),
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
                "X-Content-Type-Options": "nosniff",
                "X-Frame-Options": "DENY",
            ]
        )
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

actor ExtensionRouter {
    let client: Aria2RPCClient
    let settings: AppSettings
    let engineVersion: String
    let authorizationSecret: String
    let exposesRemoteUI: Bool
    private var requestDates: [Date] = []

    init(
        client: Aria2RPCClient,
        settings: AppSettings,
        engineVersion: String,
        authorizationSecret: String? = nil,
        exposesRemoteUI: Bool = false
    ) {
        self.client = client
        self.settings = settings
        self.engineVersion = engineVersion
        self.authorizationSecret = authorizationSecret ?? settings.extensionSecret
        self.exposesRemoteUI = exposesRemoteUI
    }

    func response(for request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return withCORS(.json(["status": "ok"]), request: request)
        }

        if exposesRemoteUI, request.method == "GET", request.path == "/" {
            return .html(Self.remoteHTML)
        }
        if exposesRemoteUI, request.method == "POST", request.path == "/mdxp" {
            guard isAuthorized(request) else { return unauthorized }
            guard withinRateLimit() else { return .json(status: 429, reason: "Too Many Requests", ["error": "rate_limited"]) }
            return await mdxp(request)
        }
        if exposesRemoteUI, request.path.hasPrefix("/api/") {
            guard isAuthorized(request) else { return unauthorized }
            guard withinRateLimit() else { return .json(status: 429, reason: "Too Many Requests", ["error": "rate_limited"]) }
            return await remoteAPI(request)
        }

        let response: HTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            response = .json(["status": "ok", "version": Self.appVersion])
        case ("GET", "/version"):
            response = .json(["app": Self.appVersion, "engine": engineVersion])
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
        authorizationSecret.isEmpty
            || request.headers["authorization"] == "Bearer \(authorizationSecret)"
    }

    private func withinRateLimit(date: Date = .now) -> Bool {
        requestDates.removeAll { date.timeIntervalSince($0) > 60 }
        guard requestDates.count < 120 else { return false }
        requestDates.append(date)
        return true
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

    private func remoteAPI(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "/api/tasks"):
                return .json(["tasks": try await allTasks().map(taskObject)])
            case ("GET", "/api/stats"):
                return .json(["stats": statObject(try await client.globalStat())])
            case ("POST", "/api/add"):
                return await add(request)
            case ("POST", let path) where path.hasPrefix("/api/tasks/"):
                let components = path.split(separator: "/")
                guard components.count == 4 else { return .json(status: 404, reason: "Not Found", ["error": "not_found"]) }
                let gid = String(components[2])
                switch components[3] {
                case "pause": try await client.pause(gid: gid, force: true)
                case "resume": try await client.resume(gid: gid)
                case "remove":
                    let task = try await client.tellStatus(gid: gid)
                    if task.status.isTerminal { try await client.removeResult(gid: gid) }
                    else { try await client.remove(gid: gid, force: true) }
                default: return .json(status: 404, reason: "Not Found", ["error": "not_found"])
                }
                return .json(["status": "ok", "gid": gid])
            default:
                return .json(status: 404, reason: "Not Found", ["error": "not_found"])
            }
        } catch {
            return serverError(error)
        }
    }

    private func mdxp(_ request: HTTPRequest) async -> HTTPResponse {
        let payload: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                throw CocoaError(.formatting)
            }
            payload = value
        } catch {
            return .json(status: 400, reason: "Bad Request", [
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"],
            ])
        }
        let id = payload["id"] ?? NSNull()
        guard payload["jsonrpc"] as? String == "2.0", let method = payload["method"] as? String else {
            return .json(status: 400, reason: "Bad Request", [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32600, "message": "Invalid Request"],
            ])
        }
        let params = payload["params"] as? [String: Any] ?? [:]
        do {
            let result: Any
            switch method {
            case "motrix/initialize":
                result = [
                    "protocolVersion": "1.0",
                    "serverInfo": ["name": "Kite", "version": "0.2.0"],
                    "capabilities": ["downloads": true, "tasks": true, "stats": true, "urlResolution": true],
                ]
            case "system/ping":
                result = ["ok": true, "timestamp": ISO8601DateFormatter().string(from: .now)]
            case "download/submit", "download/add":
                let url = params["url"] as? String
                    ?? (params["urls"] as? [String])?.first
                    ?? ((params["download"] as? [String: Any])?["url"] as? String)
                guard let url, let normalized = DownloadURLNormalizer.normalize(url) else {
                    throw Aria2RPCError(code: -32602, message: "A valid url parameter is required")
                }
                var options: [String: JSONValue] = ["dir": .string(params["directory"] as? String ?? settings.downloadDirectory)]
                if params["paused"] as? Bool == true { options["pause"] = .string("true") }
                if let filename = params["filename"] as? String { options["out"] = .string(filename) }
                let gid = try await client.addURI(normalized, options: options)
                result = ["gid": gid, "status": "submitted"]
            case "download/cancel", "task/remove":
                let gid = try requiredGID(params)
                let task = try await client.tellStatus(gid: gid)
                if task.status.isTerminal { try await client.removeResult(gid: gid) }
                else { try await client.remove(gid: gid, force: true) }
                result = ["gid": gid, "removed": true]
            case "task/list":
                result = ["tasks": try await allTasks().map(taskObject)]
            case "task/get":
                result = taskObject(try await client.tellStatus(gid: requiredGID(params)))
            case "task/pause":
                let gid = try requiredGID(params); try await client.pause(gid: gid, force: true)
                result = ["gid": gid, "status": "paused"]
            case "task/resume":
                let gid = try requiredGID(params); try await client.resume(gid: gid)
                result = ["gid": gid, "status": "active"]
            case "stats/get":
                result = statObject(try await client.globalStat())
            case "engine/status":
                result = ["running": true, "name": "aria2-next", "version": engineVersion]
            case "url/probe":
                guard let value = params["url"] as? String else {
                    throw Aria2RPCError(code: -32602, message: "A valid url parameter is required")
                }
                let preview = try await DownloadPreviewService(timeout: 10).preview(value)
                result = [
                    "url": preview.finalURL?.absoluteString ?? preview.originalValue,
                    "reachable": preview.isReachable,
                    "status": preview.statusCode ?? 0,
                    "contentType": preview.mimeType ?? "",
                    "contentLength": preview.contentLength ?? -1,
                    "filename": preview.suggestedFilename ?? "",
                    "protocol": preview.protocolKind.rawValue,
                ]
            case "url/resolve":
                guard let value = params["url"] as? String, let normalized = DownloadURLNormalizer.normalize(value) else {
                    throw Aria2RPCError(code: -32602, message: "A valid url parameter is required")
                }
                result = ["url": normalized, "kind": URL(string: normalized)?.pathExtension.lowercased() ?? ""]
            default:
                return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
            return .json(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as Aria2RPCError {
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": error.localizedDescription]])
        }
    }

    private func allTasks() async throws -> [DownloadTask] {
        async let active = client.tellActive()
        async let waiting = client.tellWaiting()
        async let stopped = client.tellStopped()
        let values = try await (active, waiting, stopped)
        return values.0 + values.1 + values.2
    }

    private func requiredGID(_ params: [String: Any]) throws -> String {
        guard let gid = params["gid"] as? String, !gid.isEmpty else {
            throw Aria2RPCError(code: -32602, message: "A gid parameter is required")
        }
        return gid
    }

    private func statObject(_ stat: GlobalStat) -> [String: Any] {
        [
            "downloadSpeed": String(stat.downloadSpeed),
            "uploadSpeed": String(stat.uploadSpeed),
            "numActive": stat.numActive,
            "numWaiting": stat.numWaiting,
            "numStopped": stat.numStopped,
        ]
    }

    private static let remoteHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Kite Remote</title><style>
    :root{color-scheme:light dark;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{max-width:960px;margin:0 auto;padding:28px;background:Canvas;color:CanvasText}
    header,.bar,.task{display:flex;gap:10px;align-items:center}.bar{margin:22px 0}input{font:inherit;padding:9px 12px;border:1px solid color-mix(in srgb,CanvasText 22%,transparent);border-radius:10px;background:Canvas;min-width:0}#url{flex:1}button{font:inherit;padding:9px 13px;border:0;border-radius:10px;background:AccentColor;color:white}.secondary{background:color-mix(in srgb,CanvasText 12%,transparent);color:CanvasText}.task{padding:13px 0;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,transparent)}.task div{flex:1;min-width:0}.name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta{opacity:.65;font-size:12px;margin-top:3px}h1{font-size:24px;margin:0}#status{margin-left:auto;opacity:.7}
    </style></head><body><header><h1>Kite</h1><span id="status">Disconnected</span></header>
    <div class="bar"><input id="secret" type="password" placeholder="Remote secret"><button class="secondary" onclick="connect()">Connect</button></div>
    <div class="bar"><input id="url" placeholder="Paste a download URL"><button onclick="add()">Download</button></div><main id="tasks"></main>
    <script>
    const $=s=>document.querySelector(s);let token=localStorage.kiteToken||localStorage.superddToken||'';$('#secret').value=token;
    async function api(path,options={}){options.headers={...(options.headers||{}),Authorization:'Bearer '+token,'Content-Type':'application/json'};let r=await fetch(path,options);if(!r.ok)throw Error(r.status);return r.json()}
    function connect(){token=$('#secret').value;localStorage.kiteToken=token;load()}
    async function add(){let url=$('#url').value.trim();if(!url)return;await api('/api/add',{method:'POST',body:JSON.stringify({url})});$('#url').value='';load()}
    async function action(gid,name){await api('/api/tasks/'+encodeURIComponent(gid)+'/'+name,{method:'POST'});load()}
    async function load(){try{let d=await api('/api/tasks');$('#status').textContent='Connected';$('#tasks').innerHTML=d.tasks.map(t=>`<section class="task"><div><div class="name">${escapeHTML(t.name)}</div><div class="meta">${t.status} · ${t.completedLength}/${t.totalLength}</div></div><button class="secondary" onclick="action('${t.gid}','${t.status==='paused'?'resume':'pause'}')">${t.status==='paused'?'Resume':'Pause'}</button><button class="secondary" onclick="action('${t.gid}','remove')">Remove</button></section>`).join('')}catch(e){$('#status').textContent='Authorization required'}}
    function escapeHTML(s){let d=document.createElement('div');d.textContent=s;return d.innerHTML}if(token)load();setInterval(()=>{if(token)load()},3000)
    </script></body></html>
    """

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"

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
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "extension-api")

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

actor RemoteControlServer {
    private var listener: NWListener?
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "remote-api")

    func start(
        preferredPort: Int,
        allowLAN: Bool,
        settings: AppSettings,
        client: Aria2RPCClient,
        engineVersion: String
    ) throws -> Int {
        listener?.cancel()
        let portNumber = try LocalPortResolver.available(startingAt: preferredPort)
        guard let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            throw Aria2RPCError(code: -1, message: "Invalid remote API port \(portNumber)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = allowLAN
        parameters.requiredLocalEndpoint = .hostPort(
            host: allowLAN ? NWEndpoint.Host("0.0.0.0") : .ipv4(.loopback),
            port: port
        )
        let listener = try NWListener(using: parameters)
        let router = ExtensionRouter(
            client: client,
            settings: settings,
            engineVersion: engineVersion,
            authorizationSecret: settings.features.remote.secret,
            exposesRemoteUI: true
        )
        listener.newConnectionHandler = { connection in
            HTTPConnection(connection: connection, router: router).start()
        }
        listener.stateUpdateHandler = { [logger] state in
            if case let .failed(error) = state { logger.error("Remote API failed: \(error.localizedDescription)") }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info("Remote Web/API listening on port \(portNumber), LAN=\(allowLAN)")
        return portNumber
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
