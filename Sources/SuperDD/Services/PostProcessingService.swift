import Foundation

enum PostProcessingError: LocalizedError, Sendable {
    case unsafeArchiveEntry(String)
    case commandFailed(String, Int32, String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeArchiveEntry(entry):
            "The archive contains an unsafe path: \(entry)"
        case let .commandFailed(command, status, message):
            "\(command) failed with exit status \(status)\(message.isEmpty ? "" : ": \(message)")"
        case let .timedOut(command):
            "\(command) did not finish within 10 minutes."
        }
    }
}

struct PostProcessingResult: Sendable {
    let outputURL: URL
    let extracted: Bool
}

actor PostProcessingService {
    static func isSupportedArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".zip") || name.hasSuffix(".cbz")
            || name.hasSuffix(".tar") || name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tgz") || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tbz2") || name.hasSuffix(".tar.xz")
            || name.hasSuffix(".txz") || name.hasSuffix(".7z")
            || name.hasSuffix(".rar")
    }

    func process(
        task: DownloadTask,
        settings: AppSettings.FeatureSettings.PostProcessing
    ) async throws -> PostProcessingResult {
        guard let sourceURL = task.primaryFileURL else {
            return PostProcessingResult(outputURL: URL(fileURLWithPath: task.directory), extracted: false)
        }

        var outputURL = sourceURL
        var extracted = false
        if settings.autoExtractArchives, Self.isSupportedArchive(sourceURL) {
            outputURL = try await extract(sourceURL, subdirectory: settings.extractionSubdirectory)
            extracted = true
            if settings.deleteArchiveAfterExtraction {
                try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
            }
        }

        let command = settings.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            try await run(
                executable: "/bin/zsh",
                arguments: ["-lc", command],
                environment: [
                    "SUPERDD_GID": task.gid,
                    "SUPERDD_NAME": task.name,
                    "SUPERDD_FILE": sourceURL.path,
                    "SUPERDD_OUTPUT": outputURL.path,
                    "SUPERDD_DIRECTORY": task.directory,
                    "SUPERDD_STATUS": task.status.rawValue,
                ]
            )
        }

        return PostProcessingResult(outputURL: outputURL, extracted: extracted)
    }

    func extract(_ archiveURL: URL, subdirectory: String = "") async throws -> URL {
        try await validateArchiveEntries(archiveURL)
        let base = archiveURL.deletingLastPathComponent()
        let configured = subdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination: URL
        if configured.isEmpty {
            let name = archiveBaseName(archiveURL)
            destination = base.appending(path: name, directoryHint: .isDirectory)
        } else {
            destination = base.appending(path: configured, directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let lowercased = archiveURL.lastPathComponent.lowercased()
        if lowercased.hasSuffix(".zip") || lowercased.hasSuffix(".cbz") {
            try await run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, destination.path])
        } else {
            try await run(executable: "/usr/bin/tar", arguments: ["-xf", archiveURL.path, "-C", destination.path])
        }
        return destination
    }

    private func validateArchiveEntries(_ archiveURL: URL) async throws {
        let lowercased = archiveURL.lastPathComponent.lowercased()
        let listing: String
        if lowercased.hasSuffix(".zip") || lowercased.hasSuffix(".cbz") {
            listing = try await runForOutput(executable: "/usr/bin/zipinfo", arguments: ["-1", archiveURL.path])
        } else {
            listing = try await runForOutput(executable: "/usr/bin/tar", arguments: ["-tf", archiveURL.path])
        }
        for rawEntry in listing.split(whereSeparator: \.isNewline) {
            let entry = String(rawEntry)
            let decoded = entry.removingPercentEncoding ?? entry
            let components = decoded.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            if decoded.hasPrefix("/") || components.contains("..") {
                throw PostProcessingError.unsafeArchiveEntry(entry)
            }
        }
    }

    private func archiveBaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tbz2", ".tgz", ".txz", ".zip", ".cbz", ".tar", ".7z", ".rar"] {
            if name.lowercased().hasSuffix(suffix) {
                name.removeLast(suffix.count)
                break
            }
        }
        return name.isEmpty ? "Extracted" : name
    }

    private func runForOutput(executable: String, arguments: [String]) async throws -> String {
        let result = try await execute(executable: executable, arguments: arguments, environment: [:])
        return result.output
    }

    private func run(executable: String, arguments: [String], environment: [String: String] = [:]) async throws {
        _ = try await execute(executable: executable, arguments: arguments, environment: environment)
    }

    private func execute(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (output: String, error: String) {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var processEnvironment = ProcessInfo.processInfo.environment
            environment.forEach { processEnvironment[$0.key] = $0.value }
            process.environment = processEnvironment
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()

            let deadline = Date().addingTimeInterval(600)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                throw PostProcessingError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
            }
            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw PostProcessingError.commandFailed(
                    URL(fileURLWithPath: executable).lastPathComponent,
                    process.terminationStatus,
                    error
                )
            }
            return (output, error)
        }.value
    }
}
