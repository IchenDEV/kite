import AppKit
import SwiftUI

struct MenuBarView: View {
    let store: DownloadStore

    var body: some View {
        Button("Show Kite") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        .keyboardShortcut("1", modifiers: .command)

        Button("New Download…") {
            store.showingAddTask = true
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        .keyboardShortcut("n", modifiers: .command)

        Divider()

        let summary = store.activeDownloadSummary
        Text("Progress  \(summary.progress.map(Formatters.percent) ?? "—")")
        Text("Download  \(Formatters.speed(summary.downloadSpeed))")
        Text("Upload  \(Formatters.speed(store.globalStat.uploadSpeed))")
        Text("Active  \(summary.activeCount)")

        Divider()

        Button(store.canPauseSelection ? "Pause Selected" : "Resume Selected") {
            Task { await store.togglePauseSelection() }
        }
        .disabled(!store.canPauseSelection && !store.canResumeSelection)

        Button("Quit Kite") { NSApp.terminate(nil) }
        .keyboardShortcut("q", modifiers: .command)
    }
}
