import Foundation
import JavaScriptCore

private struct HostRequest: Decodable {
    let pluginPath: String
    let input: String
}

private struct HostResponse: Encodable {
    let urls: [String]
    let error: String?
}

@main
private enum PluginHost {
    static func main() {
        let response: HostResponse
        do {
            let request = try JSONDecoder().decode(HostRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let pluginURL = URL(fileURLWithPath: request.pluginPath, isDirectory: true).standardizedFileURL
            let manifestURL = pluginURL.appending(path: "manifest.json")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            let entry = manifest?["entry"] as? String ?? "index.js"
            let entryURL = pluginURL.appending(path: entry).standardizedFileURL
            guard entryURL.path.hasPrefix(pluginURL.path + "/") else { throw CocoaError(.fileReadNoPermission) }

            guard let context = JSContext() else { throw CocoaError(.coderInvalidValue) }
            var exceptionMessage: String?
            context.exceptionHandler = { _, value in exceptionMessage = value?.toString() }
            context.evaluateScript("""
            'use strict';
            const console = Object.freeze({ log(){}, warn(){}, error(){} });
            const SuperDD = Object.freeze({ version: '1.0', platform: 'macOS' });
            """)
            context.evaluateScript(try String(contentsOf: entryURL, encoding: .utf8), withSourceURL: entryURL)
            if let exceptionMessage { throw NSError(domain: "SuperDDPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: exceptionMessage]) }
            guard let resolve = context.objectForKeyedSubscript("resolve"), !resolve.isUndefined else {
                throw NSError(domain: "SuperDDPlugin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Plugin must define resolve(input)"])
            }
            let value = resolve.call(withArguments: [["url": request.input, "platform": "macOS"]])
            if let exceptionMessage { throw NSError(domain: "SuperDDPlugin", code: 3, userInfo: [NSLocalizedDescriptionKey: exceptionMessage]) }
            let urls: [String]
            if value?.isArray == true {
                urls = (value?.toArray() as? [Any] ?? []).compactMap { $0 as? String }
            } else if let string = value?.toString(), !string.isEmpty, string != "undefined" {
                urls = [string]
            } else {
                urls = [request.input]
            }
            response = HostResponse(urls: urls, error: nil)
        } catch {
            response = HostResponse(urls: [], error: error.localizedDescription)
        }
        let data = (try? JSONEncoder().encode(response)) ?? Data("{\"urls\":[],\"error\":\"encoding failed\"}".utf8)
        FileHandle.standardOutput.write(data)
    }
}
