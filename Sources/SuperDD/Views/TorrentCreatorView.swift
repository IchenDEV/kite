import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TorrentCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: DownloadStore
    @State private var sourcePath = ""
    @State private var destinationPath = ""
    @State private var trackerText = ""
    @State private var comment = ""
    @State private var pieceLength = 1_048_576
    @State private var isPrivate = false
    @State private var isCreating = false

    private let creator = TorrentCreator()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create Torrent").font(.title2.weight(.semibold))
            Form {
                HStack {
                    TextField("Source file or folder", text: $sourcePath)
                    Button("Choose…") { chooseSource() }
                }
                HStack {
                    TextField("Torrent destination", text: $destinationPath)
                    Button("Choose…") { chooseDestination() }
                }
                TextField("Trackers, one per line", text: $trackerText, axis: .vertical)
                    .lineLimit(3 ... 6)
                Picker("Piece size", selection: $pieceLength) {
                    Text("256 KiB").tag(262_144)
                    Text("512 KiB").tag(524_288)
                    Text("1 MiB").tag(1_048_576)
                    Text("2 MiB").tag(2_097_152)
                    Text("4 MiB").tag(4_194_304)
                }
                Toggle("Private torrent", isOn: $isPrivate)
                TextField("Comment", text: $comment)
            }
            .formStyle(.grouped)
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourcePath.isEmpty || destinationPath.isEmpty || isCreating)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
        destinationPath = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).torrent").path
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.nameFieldStringValue = URL(fileURLWithPath: destinationPath).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.pathExtension.lowercased() == "torrent" ? url.path : url.appendingPathExtension("torrent").path
    }

    private func create() {
        isCreating = true
        let request = TorrentCreationRequest(
            sourceURL: URL(fileURLWithPath: sourcePath),
            destinationURL: URL(fileURLWithPath: destinationPath),
            trackers: trackerText.split(whereSeparator: \.isNewline).map(String.init),
            pieceLength: pieceLength,
            isPrivate: isPrivate,
            comment: comment
        )
        Task {
            do {
                try await creator.create(request)
                NSWorkspace.shared.activateFileViewerSelecting([request.destinationURL])
                dismiss()
            } catch {
                store.lastError = error.localizedDescription
                isCreating = false
            }
        }
    }
}
