import AppKit
import SwiftUI

struct MenuBarView: View {
    let store: DownloadStore

    var body: some View {
        Button("Show Super DD") {
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

        Text("Download  \(Formatters.speed(store.globalStat.downloadSpeed))")
        Text("Upload  \(Formatters.speed(store.globalStat.uploadSpeed))")
        Text("Active  \(store.activeTasks.count)")

        Divider()

        Button(store.canPauseSelection ? "Pause Selected" : "Resume Selected") {
            Task { await store.togglePauseSelection() }
        }
        .disabled(!store.canPauseSelection && !store.canResumeSelection)

        Button("Quit Super DD") { NSApp.terminate(nil) }
        .keyboardShortcut("q", modifiers: .command)
    }
}
