import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastCapturedValue = ""

    func start(handler: @escaping @MainActor ([String]) -> Void) {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, !Task.isCancelled else { break }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount != self.lastChangeCount else { continue }
                self.lastChangeCount = pasteboard.changeCount
                guard let value = pasteboard.string(forType: .string), value != self.lastCapturedValue else { continue }
                let urls = DownloadURLNormalizer.extractMany(from: value)
                guard !urls.isEmpty else { continue }
                self.lastCapturedValue = value
                handler(urls)
            }
        }
    }

    func suppressCurrentContents() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastCapturedValue = NSPasteboard.general.string(forType: .string) ?? ""
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
