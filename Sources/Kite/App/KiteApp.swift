import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var downloadStore: DownloadStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--headless") {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Download", action: #selector(openNewDownload), keyEquivalent: "")
        menu.addItem(withTitle: "Show Downloads", action: #selector(showMainWindow), keyEquivalent: "")
        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let downloadStore else { return .terminateNow }
        Task {
            await downloadStore.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func openNewDownload() {
        NotificationCenter.default.post(name: .showAddTask, object: nil)
        showMainWindow()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let showAddTask = Notification.Name("Kite.showAddTask")
}

@main
struct KiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settingsStore: SettingsStore
    @State private var downloadStore: DownloadStore

    init() {
        let settings = SettingsStore()
        _settingsStore = State(initialValue: settings)
        _downloadStore = State(initialValue: DownloadStore(settingsStore: settings))
    }

    var body: some Scene {
        WindowGroup("Kite", id: "main") {
            ContentView(store: downloadStore)
                .preferredColorScheme(settingsStore.colorScheme)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear { appDelegate.downloadStore = downloadStore }
                .task { await downloadStore.start() }
                .onOpenURL { url in Task { await downloadStore.handleExternalURL(url) } }
                .onReceive(NotificationCenter.default.publisher(for: .showAddTask)) { _ in
                    downloadStore.showingAddTask = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    downloadStore.recognizeClipboardOnActivation()
                }
        }
        .defaultSize(width: 1_120, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") { downloadStore.showingAddTask = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Torrent…") { openTorrent() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Create Torrent…") { downloadStore.showingTorrentCreator = true }
                Button("Add Links from Clipboard") { downloadStore.pasteLinksFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Downloads") {
                Button(downloadStore.canPauseSelection ? "Pause" : "Resume") {
                    Task { await downloadStore.togglePauseSelection() }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!downloadStore.canPauseSelection && !downloadStore.canResumeSelection)

                Button("Retry Failed Download") {
                    Task { await downloadStore.retrySelection() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!downloadStore.canRetrySelection)

                Menu("Queue Position") {
                    Button("Move to Top") { Task { await downloadStore.moveSelection(.top) } }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Move Up") { Task { await downloadStore.moveSelection(.up) } }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("Move Down") { Task { await downloadStore.moveSelection(.down) } }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Button("Move to Bottom") { Task { await downloadStore.moveSelection(.bottom) } }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                }
                .disabled(downloadStore.selectedTasks.allSatisfy { $0.status != .waiting && $0.status != .paused })

                Button("Remove") { Task { await downloadStore.removeSelection() } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(downloadStore.selectedTaskIDs.isEmpty)

                Divider()

                Button("Reveal in Finder") {
                    if let task = downloadStore.selectedTask { downloadStore.reveal(task) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(downloadStore.selectedTask == nil)

                Button("Refresh") { Task { await downloadStore.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(downloadStore.showingInspector ? "Hide Inspector" : "Show Inspector") {
                    downloadStore.showingInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(settingsStore: settingsStore, downloadStore: downloadStore)
                .preferredColorScheme(settingsStore.colorScheme)
        }

        MenuBarExtra {
            MenuBarView(store: downloadStore)
        } label: {
            let summary = downloadStore.activeDownloadSummary
            HStack(alignment: .center, spacing: 4) {
                KiteMenuBarMark()
                if summary.activeCount == 0 {
                    Text("Kite")
                } else {
                    Text("\(summary.progress.map(Formatters.percent) ?? "—") · \(Formatters.speed(summary.downloadSpeed))")
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(menuBarAccessibilityLabel(for: summary))
        }
        .menuBarExtraStyle(.menu)
    }

    private func openTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "torrent")!]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await downloadStore.addTorrent(at: url) }
        }
    }

    private func menuBarAccessibilityLabel(for summary: ActiveDownloadSummary) -> String {
        guard summary.activeCount > 0 else { return "Kite, no active downloads" }
        let progress = summary.progress.map(Formatters.percent) ?? "unknown progress"
        return "Kite, download progress \(progress), download speed \(Formatters.speed(summary.downloadSpeed))"
    }
}
