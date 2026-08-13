import Foundation

enum ContainerPreviewKind: String, Equatable, Sendable {
    case torrent
    case metalink

    var title: String {
        switch self {
        case .torrent: "Torrent"
        case .metalink: "Metalink"
        }
    }
}

struct ContainerPreviewFile: Equatable, Identifiable, Sendable {
    var id: String { relativePath }

    let relativePath: String
    let length: Int64?

    init(relativePath: String, length: Int64?) {
        self.relativePath = relativePath
        self.length = length
    }
}

struct ContainerPreview: Equatable, Sendable {
    let kind: ContainerPreviewKind
    let displayName: String
    let fileCount: Int
    let totalLength: Int64?
    let files: [ContainerPreviewFile]
    let trackerCount: Int?
    let error: String?

    init(
        kind: ContainerPreviewKind,
        displayName: String,
        fileCount: Int,
        totalLength: Int64?,
        files: [ContainerPreviewFile],
        trackerCount: Int?,
        error: String?
    ) {
        self.kind = kind
        self.displayName = displayName
        self.fileCount = fileCount
        self.totalLength = totalLength
        self.files = files
        self.trackerCount = trackerCount
        self.error = error
    }

    var isValid: Bool { error == nil }
}
