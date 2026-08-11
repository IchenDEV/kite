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

        Text("Download  \(Formatters.speed(store.globalStat.downloadSpeed))")
        Text("Upload  \(Formatters.speed(store.globalStat.uploadSpeed))")
        Text("Active  \(store.displayedActiveTasks.count)")

        Divider()

        Button(store.canPauseSelection ? "Pause Selected" : "Resume Selected") {
            Task { await store.togglePauseSelection() }
        }
        .disabled(!store.canPauseSelection && !store.canResumeSelection)

        Button("Quit Kite") { NSApp.terminate(nil) }
        .keyboardShortcut("q", modifiers: .command)
    }
}
