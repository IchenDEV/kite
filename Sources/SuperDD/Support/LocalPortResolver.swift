import Darwin
import Foundation

enum LocalPortResolver {
    static func available(startingAt preferredPort: Int, attempts: Int = 200) throws -> Int {
        for port in preferredPort ..< min(preferredPort + attempts, 65_536) where canBind(port: port) {
            return port
        }
        throw Aria2RPCError(code: -1, message: "No free local port near \(preferredPort)")
    }

    private static func canBind(port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
