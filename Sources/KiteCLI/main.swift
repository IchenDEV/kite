import Darwin
import Foundation

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct MDXPClient {
    let endpoint: URL
    let secret: String

    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        var request = URLRequest(url: endpoint.appending(path: "mdxp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw CLIError(message: "Remote server rejected the request. Check KITE_REMOTE_URL and KITE_REMOTE_SECRET.")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "Invalid server response")
        }
        if let error = payload["error"] as? [String: Any] {
            throw CLIError(message: error["message"] as? String ?? "MDXP request failed")
        }
        return payload["result"] ?? NSNull()
    }
}

@main
private enum KiteCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
                printHelp()
                return
            }
            let environment = ProcessInfo.processInfo.environment
            guard let base = URL(string: environment["KITE_REMOTE_URL"]
                ?? environment["SUPERDD_REMOTE_URL"]
                ?? "http://127.0.0.1:29120/") else {
                throw CLIError(message: "KITE_REMOTE_URL is invalid")
            }
            let secret = environment["KITE_REMOTE_SECRET"] ?? environment["SUPERDD_REMOTE_SECRET"] ?? ""
            guard !secret.isEmpty else { throw CLIError(message: "Set KITE_REMOTE_SECRET to the secret shown in Kite Settings → Network.") }
            let client = MDXPClient(endpoint: base, secret: secret)
            let result: Any
            switch command {
            case "ping": result = try await client.call("system/ping")
            case "list": result = try await client.call("task/list")
            case "stats": result = try await client.call("stats/get")
            case "add":
                guard arguments.count >= 2 else { throw CLIError(message: "Usage: kitectl add <url> [directory]") }
                var params: [String: Any] = ["url": arguments[1]]
                if arguments.count >= 3 { params["directory"] = arguments[2] }
                result = try await client.call("download/add", params: params)
            case "get", "pause", "resume", "remove":
                guard arguments.count >= 2 else { throw CLIError(message: "Usage: kitectl \(command) <gid>") }
                let method = command == "get" ? "task/get" : "task/\(command)"
                result = try await client.call(method, params: ["gid": arguments[1]])
            default: throw CLIError(message: "Unknown command: \(command)")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("kitectl: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printHelp() {
        print("""
        kitectl — control Kite through its authenticated MDXP 1.0 endpoint

        Commands:
          ping                     Check the remote service
          add <url> [directory]    Add a download
          list                     List tasks
          get <gid>                Inspect a task
          pause|resume <gid>       Change task state
          remove <gid>             Remove a task
          stats                    Show aggregate transfer statistics

        Environment:
          KITE_REMOTE_URL          Defaults to http://127.0.0.1:29120/
          KITE_REMOTE_SECRET       Required Bearer token from Settings → Network

        Legacy SUPERDD_REMOTE_URL and SUPERDD_REMOTE_SECRET variables remain accepted.
        """)
    }
}
