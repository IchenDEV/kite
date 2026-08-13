import Foundation

struct ContainerPreviewService: Sendable {
    private static let maximumInputSize = 32 * 1_024 * 1_024

    func preview(fileAt url: URL) -> ContainerPreview {
        let extensionName = url.pathExtension.lowercased()
        let fallbackName = url.lastPathComponent.isEmpty ? "Imported file" : url.lastPathComponent
        let kind: ContainerPreviewKind

        switch extensionName {
        case "torrent":
            kind = .torrent
        case "metalink", "meta4":
            kind = .metalink
        default:
            return .failure(
                kind: extensionName == "xml" ? .metalink : .torrent,
                displayName: fallbackName,
                message: "Choose a .torrent, .metalink, or .meta4 file."
            )
        }

        guard url.isFileURL else {
            return .failure(
                kind: kind,
                displayName: fallbackName,
                message: "Container previews only read local files."
            )
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else {
                throw ContainerPreviewParsingError.notAFile
            }
            if let fileSize = values.fileSize, fileSize > Self.maximumInputSize {
                throw ContainerPreviewParsingError.inputTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return preview(data: data, kind: kind, displayName: fallbackName)
        } catch let error as ContainerPreviewParsingError {
            return .failure(kind: kind, displayName: fallbackName, message: error.localizedDescription)
        } catch {
            return .failure(
                kind: kind,
                displayName: fallbackName,
                message: "Kite could not read this file: \(error.localizedDescription)"
            )
        }
    }

    func preview(
        data: Data,
        kind: ContainerPreviewKind,
        displayName: String? = nil
    ) -> ContainerPreview {
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = trimmedDisplayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(kind.title) file"

        do {
            guard !data.isEmpty else { throw ContainerPreviewParsingError.emptyInput }
            guard data.count <= Self.maximumInputSize else {
                throw ContainerPreviewParsingError.inputTooLarge
            }

            switch kind {
            case .torrent:
                return try TorrentPreviewParser.parse(data)
            case .metalink:
                return try MetalinkPreviewParser.parse(data, fallbackName: fallbackName)
            }
        } catch let error as ContainerPreviewParsingError {
            return .failure(kind: kind, displayName: fallbackName, message: error.localizedDescription)
        } catch {
            return .failure(
                kind: kind,
                displayName: fallbackName,
                message: "Kite could not parse this file: \(error.localizedDescription)"
            )
        }
    }
}

private enum ContainerPreviewParsingError: LocalizedError {
    case emptyInput
    case inputTooLarge
    case notAFile
    case malformedTorrent(String)
    case invalidTorrent(String)
    case malformedMetalink
    case invalidMetalink(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "This container file is empty."
        case .inputTooLarge:
            "This container file is too large to preview safely."
        case .notAFile:
            "The selected item is not a regular file."
        case let .malformedTorrent(reason):
            "This torrent is malformed: \(reason)"
        case let .invalidTorrent(reason):
            "This torrent cannot be previewed: \(reason)"
        case .malformedMetalink:
            "This Metalink document is malformed."
        case let .invalidMetalink(reason):
            "This Metalink cannot be previewed: \(reason)"
        }
    }
}

private extension ContainerPreview {
    static func failure(
        kind: ContainerPreviewKind,
        displayName: String,
        message: String
    ) -> ContainerPreview {
        ContainerPreview(
            kind: kind,
            displayName: displayName,
            fileCount: 0,
            totalLength: nil,
            files: [],
            trackerCount: kind == .torrent ? 0 : nil,
            error: message
        )
    }
}

private indirect enum BencodeValue {
    case integer(Int64)
    case bytes(Data)
    case list([BencodeValue])
    case dictionary([Data: BencodeValue])
}

private struct BencodeDecoder {
    private static let maximumDepth = 48
    private static let maximumNodes = 100_000
    private static let maximumCollectionCount = 50_000
    private static let maximumByteStringLength = 24 * 1_024 * 1_024
    private static let maximumKeyLength = 1_024

    private let bytes: [UInt8]
    private var index = 0
    private var nodeCount = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func decode() throws -> BencodeValue {
        let value = try parseValue(depth: 0)
        guard index == bytes.count else {
            throw malformed("unexpected data after the root value")
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> BencodeValue {
        guard depth <= Self.maximumDepth else {
            throw malformed("nesting is too deep")
        }
        nodeCount += 1
        guard nodeCount <= Self.maximumNodes else {
            throw malformed("the structure contains too many values")
        }
        guard index < bytes.count else { throw malformed("unexpected end of file") }

        switch bytes[index] {
        case UInt8(ascii: "i"):
            return .integer(try parseInteger())
        case UInt8(ascii: "l"):
            return .list(try parseList(depth: depth))
        case UInt8(ascii: "d"):
            return .dictionary(try parseDictionary(depth: depth))
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return .bytes(try parseByteString(maximumLength: Self.maximumByteStringLength))
        default:
            throw malformed("an invalid value marker was found")
        }
    }

    private mutating func parseInteger() throws -> Int64 {
        index += 1
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        let digitStart = index
        while index < bytes.count, bytes[index].isASCIIDigit {
            index += 1
            guard index - digitStart <= 19 else {
                throw malformed("an integer is out of range")
            }
        }
        guard index > digitStart, index < bytes.count, bytes[index] == UInt8(ascii: "e") else {
            throw malformed("an integer is not terminated")
        }
        guard !(bytes[digitStart] == UInt8(ascii: "0") && index - digitStart > 1),
              !(digitStart > start && bytes[digitStart] == UInt8(ascii: "0")) else {
            throw malformed("an integer has a non-canonical representation")
        }
        let text = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard let value = Int64(text) else { throw malformed("an integer is out of range") }
        index += 1
        return value
    }

    private mutating func parseList(depth: Int) throws -> [BencodeValue] {
        index += 1
        var values: [BencodeValue] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
            guard values.count < Self.maximumCollectionCount else {
                throw malformed("a list contains too many values")
            }
            values.append(try parseValue(depth: depth + 1))
        }
        guard index < bytes.count else { throw malformed("a list is not terminated") }
        index += 1
        return values
    }

    private mutating func parseDictionary(depth: Int) throws -> [Data: BencodeValue] {
        index += 1
        var values: [Data: BencodeValue] = [:]
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
            guard values.count < Self.maximumCollectionCount else {
                throw malformed("a dictionary contains too many values")
            }
            guard bytes[index].isASCIIDigit else {
                throw malformed("a dictionary key is not a byte string")
            }
            let key = try parseByteString(maximumLength: Self.maximumKeyLength)
            guard values[key] == nil else { throw malformed("a dictionary key is duplicated") }
            values[key] = try parseValue(depth: depth + 1)
        }
        guard index < bytes.count else { throw malformed("a dictionary is not terminated") }
        index += 1
        return values
    }

    private mutating func parseByteString(maximumLength: Int) throws -> Data {
        let lengthStart = index
        while index < bytes.count, bytes[index].isASCIIDigit {
            index += 1
            guard index - lengthStart <= 9 else {
                throw malformed("a byte string length is out of range")
            }
        }
        guard index > lengthStart, index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
            throw malformed("a byte string has an invalid length")
        }
        guard !(bytes[lengthStart] == UInt8(ascii: "0") && index - lengthStart > 1) else {
            throw malformed("a byte string length has a non-canonical representation")
        }
        let lengthText = String(decoding: bytes[lengthStart ..< index], as: UTF8.self)
        guard let length = Int(lengthText), length <= maximumLength else {
            throw malformed("a byte string is too large")
        }
        index += 1
        guard length <= bytes.count - index else {
            throw malformed("a byte string extends beyond the end of the file")
        }
        let end = index + length
        let value = Data(bytes[index ..< end])
        index = end
        return value
    }

    private func malformed(_ reason: String) -> ContainerPreviewParsingError {
        .malformedTorrent(reason)
    }
}

private enum TorrentPreviewParser {
    private static let maximumFiles = 20_000
    private static let maximumPathLength = 16_384
    private static let maximumPathComponentLength = 1_024

    static func parse(_ data: Data) throws -> ContainerPreview {
        var decoder = BencodeDecoder(data: data)
        guard case let .dictionary(root) = try decoder.decode() else {
            throw ContainerPreviewParsingError.invalidTorrent("the root value is not a dictionary")
        }
        guard case let .dictionary(info)? = root.value(for: "info") else {
            throw ContainerPreviewParsingError.invalidTorrent("the info dictionary is missing")
        }

        let name = try preferredString(
            in: info,
            preferredKey: "name.utf-8",
            fallbackKey: "name",
            fieldName: "name"
        )
        let safeName = try normalizedPathComponent(name, fieldName: "name")

        let files: [ContainerPreviewFile]
        if let filesValue = info.value(for: "files") {
            guard info.value(for: "length") == nil else {
                throw ContainerPreviewParsingError.invalidTorrent("info contains both length and files")
            }
            guard case let .list(fileValues) = filesValue, !fileValues.isEmpty else {
                throw ContainerPreviewParsingError.invalidTorrent("the files list is empty or invalid")
            }
            guard fileValues.count <= maximumFiles else {
                throw ContainerPreviewParsingError.invalidTorrent("the files list is too large")
            }
            files = try fileValues.map(parseFile)
            guard Set(files.map(\.relativePath)).count == files.count else {
                throw ContainerPreviewParsingError.invalidTorrent("two files use the same path")
            }
        } else {
            let length = try nonnegativeLength(info.value(for: "length"), fieldName: "length")
            files = [ContainerPreviewFile(relativePath: safeName, length: length)]
        }

        let totalLength = try checkedTotal(files.compactMap(\.length), kind: .torrent)
        let trackerCount = try trackers(in: root).count
        return ContainerPreview(
            kind: .torrent,
            displayName: safeName,
            fileCount: files.count,
            totalLength: totalLength,
            files: files,
            trackerCount: trackerCount,
            error: nil
        )
    }

    private static func parseFile(_ value: BencodeValue) throws -> ContainerPreviewFile {
        guard case let .dictionary(file) = value else {
            throw ContainerPreviewParsingError.invalidTorrent("a file entry is not a dictionary")
        }
        let length = try nonnegativeLength(file.value(for: "length"), fieldName: "file length")
        let components = try preferredPath(in: file)
        let relativePath = components.joined(separator: "/")
        guard relativePath.utf8.count <= maximumPathLength else {
            throw ContainerPreviewParsingError.invalidTorrent("a file path is too long")
        }
        return ContainerPreviewFile(relativePath: relativePath, length: length)
    }

    private static func preferredPath(in dictionary: [Data: BencodeValue]) throws -> [String] {
        if let preferred = dictionary.value(for: "path.utf-8") {
            do {
                return try pathComponents(from: preferred, fieldName: "path.utf-8")
            } catch ContainerPreviewParsingError.invalidTorrent(let reason)
                where reason.contains("valid UTF-8") {
                // Some older creators emitted an invalid UTF-8 extension but kept a usable legacy path.
            }
        }
        guard let fallback = dictionary.value(for: "path") else {
            throw ContainerPreviewParsingError.invalidTorrent("a file path is missing")
        }
        return try pathComponents(from: fallback, fieldName: "path")
    }

    private static func pathComponents(
        from value: BencodeValue,
        fieldName: String
    ) throws -> [String] {
        guard case let .list(values) = value, !values.isEmpty else {
            throw ContainerPreviewParsingError.invalidTorrent("\(fieldName) is not a nonempty list")
        }
        return try values.map { value in
            guard case let .bytes(data) = value, let component = String(data: data, encoding: .utf8) else {
                throw ContainerPreviewParsingError.invalidTorrent("\(fieldName) is not valid UTF-8")
            }
            return try normalizedPathComponent(component, fieldName: fieldName)
        }
    }

    private static func preferredString(
        in dictionary: [Data: BencodeValue],
        preferredKey: String,
        fallbackKey: String,
        fieldName: String
    ) throws -> String {
        if let preferred = dictionary.value(for: preferredKey) {
            guard case let .bytes(data) = preferred else {
                throw ContainerPreviewParsingError.invalidTorrent("\(preferredKey) is not a byte string")
            }
            if let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        guard case let .bytes(data)? = dictionary.value(for: fallbackKey),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ContainerPreviewParsingError.invalidTorrent("\(fieldName) is missing or is not valid UTF-8")
        }
        return value
    }

    private static func normalizedPathComponent(
        _ component: String,
        fieldName: String
    ) throws -> String {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.utf8.count <= maximumPathComponentLength,
              !component.contains("/"),
              !component.contains("\\"),
              !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ContainerPreviewParsingError.invalidTorrent("\(fieldName) contains an unsafe path component")
        }
        return component
    }

    private static func nonnegativeLength(
        _ value: BencodeValue?,
        fieldName: String
    ) throws -> Int64 {
        guard case let .integer(length)? = value, length >= 0 else {
            throw ContainerPreviewParsingError.invalidTorrent("\(fieldName) is missing or invalid")
        }
        return length
    }

    private static func trackers(in root: [Data: BencodeValue]) throws -> Set<String> {
        var result: Set<String> = []
        if let announce = root.value(for: "announce") {
            try collectTrackers(from: announce, allowList: false, into: &result)
        }
        if let announceList = root.value(for: "announce-list") {
            try collectTrackers(from: announceList, allowList: true, into: &result)
        }
        return result
    }

    private static func collectTrackers(
        from value: BencodeValue,
        allowList: Bool,
        into result: inout Set<String>
    ) throws {
        switch value {
        case let .bytes(data):
            guard let tracker = String(data: data, encoding: .utf8) else {
                throw ContainerPreviewParsingError.invalidTorrent("a tracker URL is not valid UTF-8")
            }
            let trimmed = tracker.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.insert(trimmed) }
        case let .list(values) where allowList:
            for value in values {
                try collectTrackers(from: value, allowList: true, into: &result)
            }
        default:
            throw ContainerPreviewParsingError.invalidTorrent("the tracker list has an invalid shape")
        }
    }
}

private enum MetalinkPreviewParser {
    static func parse(_ data: Data, fallbackName: String) throws -> ContainerPreview {
        let delegate = MetalinkXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed else { throw ContainerPreviewParsingError.malformedMetalink }
        guard delegate.sawMetalinkRoot else {
            throw ContainerPreviewParsingError.invalidMetalink("the metalink root element is missing")
        }
        guard !delegate.files.isEmpty else {
            throw ContainerPreviewParsingError.invalidMetalink("the document does not contain any files")
        }
        guard Set(delegate.files.map(\.relativePath)).count == delegate.files.count else {
            throw ContainerPreviewParsingError.invalidMetalink("two files use the same path")
        }

        let knownLengths = delegate.files.compactMap(\.length)
        let totalLength = knownLengths.count == delegate.files.count
            ? try checkedTotal(knownLengths, kind: .metalink)
            : nil
        let displayName = delegate.files.count == 1
            ? delegate.files[0].relativePath
            : fallbackName
        return ContainerPreview(
            kind: .metalink,
            displayName: displayName,
            fileCount: delegate.files.count,
            totalLength: totalLength,
            files: delegate.files,
            trackerCount: nil,
            error: nil
        )
    }
}

private final class MetalinkXMLDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    private static let maximumDepth = 64
    private static let maximumElements = 100_000
    private static let maximumFiles = 20_000
    static let maximumPathLength = 16_384
    private static let maximumSizeTextLength = 32

    private struct PendingFile {
        let relativePath: String
        let depth: Int
        var length: Int64?
        var sawSize = false
    }

    private var depth = 0
    private var elementCount = 0
    private var pendingFile: PendingFile?
    private var sizeDepth: Int?
    private var sizeText = ""

    private(set) var files: [ContainerPreviewFile] = []
    private(set) var sawMetalinkRoot = false
    private(set) var failure: ContainerPreviewParsingError?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        depth += 1
        elementCount += 1
        guard depth <= Self.maximumDepth, elementCount <= Self.maximumElements else {
            fail(.invalidMetalink("the XML structure is too large or deeply nested"), parser: parser)
            return
        }

        let name = localName(elementName, qualifiedName: qName)
        if depth == 1 {
            guard name == "metalink" else {
                fail(.invalidMetalink("the root element is not metalink"), parser: parser)
                return
            }
            sawMetalinkRoot = true
        }

        switch name {
        case "file":
            guard pendingFile == nil else {
                fail(.invalidMetalink("file elements cannot be nested"), parser: parser)
                return
            }
            guard files.count < Self.maximumFiles else {
                fail(.invalidMetalink("the document contains too many files"), parser: parser)
                return
            }
            guard let rawName = attributeDict.first(where: {
                localName($0.key, qualifiedName: nil) == "name"
            })?.value else {
                fail(.invalidMetalink("a file name is missing"), parser: parser)
                return
            }
            do {
                pendingFile = PendingFile(
                    relativePath: try normalizedMetalinkPath(rawName),
                    depth: depth
                )
            } catch let error as ContainerPreviewParsingError {
                fail(error, parser: parser)
            } catch {
                fail(.invalidMetalink("a file name is invalid"), parser: parser)
            }
        case "size" where pendingFile != nil:
            guard sizeDepth == nil, pendingFile?.sawSize == false else {
                fail(.invalidMetalink("a file contains more than one size"), parser: parser)
                return
            }
            sizeDepth = depth
            sizeText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil, sizeDepth != nil else { return }
        guard sizeText.utf8.count + string.utf8.count <= Self.maximumSizeTextLength else {
            fail(.invalidMetalink("a file size is too long"), parser: parser)
            return
        }
        sizeText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else {
            depth = max(depth - 1, 0)
            return
        }
        let name = localName(elementName, qualifiedName: qName)

        if name == "size", sizeDepth == depth {
            let trimmed = sizeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let length = parseNonnegativeInt64(trimmed) else {
                fail(.invalidMetalink("a file size is invalid"), parser: parser)
                return
            }
            pendingFile?.length = length
            pendingFile?.sawSize = true
            sizeDepth = nil
            sizeText = ""
        } else if name == "file", pendingFile?.depth == depth {
            if let pendingFile {
                files.append(ContainerPreviewFile(
                    relativePath: pendingFile.relativePath,
                    length: pendingFile.length
                ))
            }
            self.pendingFile = nil
        }
        depth = max(depth - 1, 0)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(.invalidMetalink("external XML entities are not allowed"), parser: parser)
        return nil
    }

    private func fail(_ error: ContainerPreviewParsingError, parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

private func checkedTotal(
    _ lengths: [Int64],
    kind: ContainerPreviewKind
) throws -> Int64 {
    var total: Int64 = 0
    for length in lengths {
        let (sum, overflow) = total.addingReportingOverflow(length)
        guard !overflow else {
            switch kind {
            case .torrent:
                throw ContainerPreviewParsingError.invalidTorrent("the total file size is out of range")
            case .metalink:
                throw ContainerPreviewParsingError.invalidMetalink("the total file size is out of range")
            }
        }
        total = sum
    }
    return total
}

private func normalizedMetalinkPath(_ rawValue: String) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
          value.utf8.count <= MetalinkXMLDelegate.maximumPathLength,
          !value.hasPrefix("/"),
          !value.hasPrefix("\\"),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ContainerPreviewParsingError.invalidMetalink("a file name contains an unsafe path")
    }
    let components = value.split(
        omittingEmptySubsequences: false,
        whereSeparator: { $0 == "/" || $0 == "\\" }
    )
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ContainerPreviewParsingError.invalidMetalink("a file name contains an unsafe path")
    }
    return components.joined(separator: "/")
}

private func parseNonnegativeInt64(_ value: String) -> Int64? {
    guard !value.isEmpty,
          value.allSatisfy({ $0.isASCII && $0.isNumber }),
          let result = Int64(value),
          result >= 0 else {
        return nil
    }
    return result
}

private func localName(_ name: String, qualifiedName: String?) -> String {
    let candidate = name.isEmpty ? (qualifiedName ?? "") : name
    return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
}

private extension Dictionary where Key == Data, Value == BencodeValue {
    func value(for key: String) -> BencodeValue? {
        self[Data(key.utf8)]
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }
}
