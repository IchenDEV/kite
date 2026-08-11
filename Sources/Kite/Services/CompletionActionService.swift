import AppKit
import Foundation

enum CompletionActionService {
    @MainActor
    static func perform(_ action: AppSettings.CompletionAction) throws {
        switch action {
        case .none:
            return
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            try runAppleScript("tell application \"System Events\" to sleep")
        case .shutDown:
            try runAppleScript("tell application \"System Events\" to shut down")
        }
    }

    private static func runAppleScript(_ source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(.executableRuntimeMismatch, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "The completion action failed." : message])
        }
    }
}
