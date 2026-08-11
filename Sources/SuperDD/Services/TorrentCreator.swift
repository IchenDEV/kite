import CryptoKit
import Foundation

enum TorrentCreatorError: LocalizedError, Sendable {
    case noFiles
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .noFiles: "The selected folder contains no regular files."
        case .sourceUnavailable: "The selected file or folder is unavailable."
        }
    }
}

struct TorrentCreationRequest: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let trackers: [String]
    let pieceLength: Int
    let isPrivate: Bool
    let comment: String
}

actor TorrentCreator {
    func create(_ request: TorrentCreationRequest) async throws {
        try await Task.detached(priority: .utility) {
            let files = try collectFiles(at: request.sourceURL)
            guard !files.isEmpty else { throw TorrentCreatorError.noFiles }
            let pieces = try hashPieces(files: files, pieceLength: max(request.pieceLength, 16 * 1_024))

            var info: [String: Bencode] = [
                "name": .bytes(Data(request.sourceURL.lastPathComponent.utf8)),
                "piece length": .integer(Int64(max(request.pieceLength, 16 * 1_024))),
                "pieces": .bytes(pieces),
            ]
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: request.sourceURL.path, isDirectory: &isDirectory) else {
                throw TorrentCreatorError.sourceUnavailable
            }
            if isDirectory.boolValue {
                info["files"] = .list(files.map { file in
                    let relative = file.url.pathComponents.dropFirst(request.sourceURL.pathComponents.count)
                    return .dictionary([
                        "length": .integer(file.length),
                        "path": .list(relative.map { .bytes(Data($0.utf8)) }),
                    ])
                })
            } else {
                info["length"] = .integer(files[0].length)
            }
            if request.isPrivate { info["private"] = .integer(1) }

            var root: [String: Bencode] = [
                "created by": .bytes(Data("Super DD".utf8)),
                "creation date": .integer(Int64(Date().timeIntervalSince1970)),
                "info": .dictionary(info),
            ]
            let trackers = request.trackers.filter { !$0.isEmpty }
            if let first = trackers.first {
                root["announce"] = .bytes(Data(first.utf8))
                root["announce-list"] = .list(trackers.map { .list([.bytes(Data($0.utf8))]) })
            }
            if !request.comment.isEmpty { root["comment"] = .bytes(Data(request.comment.utf8)) }
            try Bencode.dictionary(root).encoded().write(to: request.destinationURL, options: .atomic)
        }.value
    }
}

private struct TorrentInputFile: Sendable {
    let url: URL
    let length: Int64
}

private func collectFiles(at sourceURL: URL) throws -> [TorrentInputFile] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
        throw TorrentCreatorError.sourceUnavailable
    }
    if !isDirectory.boolValue {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return [] }
        return [TorrentInputFile(url: sourceURL, length: Int64(values.fileSize ?? 0))]
    }
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    let enumerator = FileManager.default.enumerator(
        at: sourceURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    var files: [TorrentInputFile] = []
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isRegularFile == true, values.isSymbolicLink != true {
            files.append(TorrentInputFile(url: url, length: Int64(values.fileSize ?? 0)))
        }
    }
    return files.sorted { $0.url.path < $1.url.path }
}

private func hashPieces(files: [TorrentInputFile], pieceLength: Int) throws -> Data {
    var result = Data()
    var piece = Data()
    for file in files {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        while true {
            let needed = pieceLength - piece.count
            guard let data = try handle.read(upToCount: needed), !data.isEmpty else { break }
            piece.append(data)
            if piece.count == pieceLength {
                result.append(contentsOf: Insecure.SHA1.hash(data: piece))
                piece.removeAll(keepingCapacity: true)
            }
        }
    }
    if !piece.isEmpty { result.append(contentsOf: Insecure.SHA1.hash(data: piece)) }
    return result
}

private enum Bencode {
    case integer(Int64)
    case bytes(Data)
    case list([Bencode])
    case dictionary([String: Bencode])

    func encoded() -> Data {
        switch self {
        case let .integer(value): Data("i\(value)e".utf8)
        case let .bytes(value): Data("\(value.count):".utf8) + value
        case let .list(values): Data("l".utf8) + values.reduce(into: Data()) { $0.append($1.encoded()) } + Data("e".utf8)
        case let .dictionary(values):
            Data("d".utf8) + values.keys.sorted().reduce(into: Data()) { result, key in
                result.append(Bencode.bytes(Data(key.utf8)).encoded())
                result.append(values[key]!.encoded())
            } + Data("e".utf8)
        }
    }
}
