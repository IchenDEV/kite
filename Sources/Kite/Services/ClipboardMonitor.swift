import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func start(handler: @escaping @MainActor ([String]) -> Void) {
        stop()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, !Task.isCancelled else { break }
                let urls = self.consumeCurrentContents()
                guard !urls.isEmpty else { continue }
                handler(urls)
            }
        }
    }

    func consumeCurrentContents() -> [String] {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return [] }
        lastChangeCount = changeCount
        guard let value = pasteboard.string(forType: .string) else { return [] }
        return DownloadURLNormalizer.extractMany(from: value)
    }

    func suppressCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
