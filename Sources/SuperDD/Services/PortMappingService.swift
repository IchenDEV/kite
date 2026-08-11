import Darwin
import Foundation
import Network

private final class UDPExchangeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Data, Error>

    init(connection: NWConnection, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(with: result)
    }
}

enum PortMappingState: Equatable, Sendable {
    case disabled
    case mapping
    case mapped([Int])
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .mapping: "Mapping ports…"
        case let .mapped(ports): "Mapped \(ports.map(String.init).joined(separator: ", "))"
        case let .failed(message): "Failed: \(message)"
        }
    }
}

actor PortMappingService {
    private var mappedPorts: [(port: Int, transport: String, protocolName: String, controlURL: URL?, serviceType: String?)] = []

    func mapPorts(settings: AppSettings) async -> PortMappingState {
        await removeMappings()
        let policy = settings.features.networkPolicy
        guard policy.enableNATPMP || policy.enableUPnP else { return .disabled }
        let requests = [
            (settings.btListenPort, "TCP"),
            (settings.dhtListenPort, "UDP"),
        ]
        var mapped = Set<Int>()
        var errors: [String] = []

        if policy.enableNATPMP {
            do {
                let gateway = try await defaultGateway()
                for (port, transport) in requests {
                    let external = try await mapNATPMP(gateway: gateway, port: port, transport: transport, lifetime: 7_200)
                    mapped.insert(external)
                    mappedPorts.append((port, transport, "natpmp", nil, nil))
                }
            } catch {
                errors.append("NAT-PMP \(error.localizedDescription)")
            }
        }

        if policy.enableUPnP {
            do {
                let service = try await discoverUPnP()
                let localAddress = try localIPv4Address()
                for (port, transport) in requests {
                    try await addUPnPMapping(
                        service: service,
                        port: port,
                        transport: transport,
                        localAddress: localAddress
                    )
                    mapped.insert(port)
                    mappedPorts.append((port, transport, "upnp", service.controlURL, service.serviceType))
                }
            } catch {
                errors.append("UPnP \(error.localizedDescription)")
            }
        }
        if !mapped.isEmpty { return .mapped(mapped.sorted()) }
        return .failed(errors.joined(separator: "; "))
    }

    func removeMappings() async {
        for mapping in mappedPorts {
            if mapping.protocolName == "natpmp", let gateway = try? await defaultGateway() {
                _ = try? await mapNATPMP(gateway: gateway, port: mapping.port, transport: mapping.transport, lifetime: 0)
            } else if mapping.protocolName == "upnp", let controlURL = mapping.controlURL, let serviceType = mapping.serviceType {
                try? await deleteUPnPMapping(
                    service: UPnPService(controlURL: controlURL, serviceType: serviceType),
                    port: mapping.port,
                    transport: mapping.transport
                )
            }
        }
        mappedPorts.removeAll()
    }

    private func defaultGateway() async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
            process.arguments = ["-n", "get", "default"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0,
                  let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("gateway:") }),
                  let gateway = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
                  !gateway.isEmpty else { throw URLError(.cannotFindHost) }
            return gateway
        }.value
    }

    private func mapNATPMP(gateway: String, port: Int, transport: String, lifetime: UInt32) async throws -> Int {
        var request = Data([0, transport == "UDP" ? 1 : 2, 0, 0])
        request.appendUInt16(UInt16(clamping: port))
        request.appendUInt16(UInt16(clamping: port))
        request.appendUInt32(lifetime)
        let response = try await udpExchange(host: gateway, port: 5_351, payload: request)
        guard response.count >= 16 else { throw URLError(.badServerResponse) }
        let result = response.uint16(at: 2)
        guard result == 0 else { throw NSError(domain: "NAT-PMP", code: Int(result)) }
        return Int(response.uint16(at: 10))
    }

    private func udpExchange(host: String, port: UInt16, payload: Data) async throws -> Data {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        return try await withCheckedThrowingContinuation { continuation in
            let completion = UDPExchangeCompletion(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error { completion.finish(.failure(error)); return }
                        connection.receiveMessage { data, _, _, error in
                            if let data { completion.finish(.success(data)) }
                            else { completion.finish(.failure(error ?? URLError(.timedOut))) }
                        }
                    })
                case let .failed(error): completion.finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            Task {
                try? await Task.sleep(for: .seconds(3))
                completion.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    private struct UPnPService: Sendable {
        let controlURL: URL
        let serviceType: String
    }

    private func discoverUPnP() async throws -> UPnPService {
        let search = Data("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r

        """.utf8)
        let response = try await udpExchange(host: "239.255.255.250", port: 1_900, payload: search)
        let header = String(decoding: response, as: UTF8.self)
        guard let locationLine = header.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().hasPrefix("location:") }),
              let value = locationLine.split(separator: ":", maxSplits: 1).last,
              let location = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badServerResponse)
        }
        let (data, _) = try await URLSession.shared.data(from: location)
        let xml = String(decoding: data, as: UTF8.self)
        for serviceType in [
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
        ] {
            guard let serviceRange = xml.range(of: "<serviceType>\(serviceType)</serviceType>") else { continue }
            let tail = xml[serviceRange.upperBound...]
            guard let start = tail.range(of: "<controlURL>"), let end = tail.range(of: "</controlURL>"), start.upperBound <= end.lowerBound else { continue }
            let path = String(tail[start.upperBound ..< end.lowerBound])
            guard let controlURL = URL(string: path, relativeTo: location)?.absoluteURL else { continue }
            return UPnPService(controlURL: controlURL, serviceType: serviceType)
        }
        throw URLError(.unsupportedURL)
    }

    private func addUPnPMapping(service: UPnPService, port: Int, transport: String, localAddress: String) async throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:AddPortMapping xmlns:u="\(service.serviceType)">
            <NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort>
            <NewProtocol>\(transport)</NewProtocol><NewInternalPort>\(port)</NewInternalPort>
            <NewInternalClient>\(localAddress)</NewInternalClient><NewEnabled>1</NewEnabled>
            <NewPortMappingDescription>Super DD</NewPortMappingDescription><NewLeaseDuration>7200</NewLeaseDuration>
          </u:AddPortMapping></s:Body>
        </s:Envelope>
        """
        try await sendSOAP(service: service, action: "AddPortMapping", body: body)
    }

    private func deleteUPnPMapping(service: UPnPService, port: Int, transport: String) async throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:DeletePortMapping xmlns:u="\(service.serviceType)">
            <NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>\(transport)</NewProtocol>
          </u:DeletePortMapping></s:Body>
        </s:Envelope>
        """
        try await sendSOAP(service: service, action: "DeletePortMapping", body: body)
    }

    private func sendSOAP(service: UPnPService, action: String, body: String) async throws {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func localIPv4Address() throws -> String {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { throw URLError(.cannotFindHost) }
        defer { freeifaddrs(addressList) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var address = interface.ifa_addr.pointee
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&address, socklen_t(address.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            pointer = interface.ifa_next
        }
        throw URLError(.cannotFindHost)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff)); append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }
    func uint16(at index: Int) -> UInt16 {
        (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }
}
