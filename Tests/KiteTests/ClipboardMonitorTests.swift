import AppKit
import Testing
@testable import Kite

@Suite("Clipboard activation recognition")
@MainActor
struct ClipboardMonitorTests {
    @Test("Existing clipboard contents are consumed once")
    func consumesExistingContentsOnce() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/file.zip", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: pasteboard)

        #expect(monitor.consumeCurrentContents() == ["https://example.com/file.zip"])
        #expect(monitor.consumeCurrentContents().isEmpty)
    }

    @Test("Copying the same link again creates a new clipboard change")
    func recognizesRecopiedLink() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("magnet:?xt=urn:btih:123", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: pasteboard)

        #expect(monitor.consumeCurrentContents() == ["magnet:?xt=urn:btih:123"])
        pasteboard.clearContents()
        pasteboard.setString("magnet:?xt=urn:btih:123", forType: .string)
        #expect(monitor.consumeCurrentContents() == ["magnet:?xt=urn:btih:123"])
    }

    @Test("Suppressed app-authored clipboard contents are not captured")
    func suppressesCurrentContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/copied-by-kite", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: pasteboard)

        monitor.suppressCurrentContents()

        #expect(monitor.consumeCurrentContents().isEmpty)
    }
}
