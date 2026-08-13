import Foundation
import Testing
@testable import Kite

@Suite("Download URL normalization")
struct DownloadURLNormalizerTests {
    @Test("Thunder links decode their AA and ZZ envelope")
    func thunder() {
        let wrapped = "AAhttps://example.com/file.isoZZ"
        let encoded = Data(wrapped.utf8).base64EncodedString()
        #expect(DownloadURLNormalizer.normalize("thunder://\(encoded)") == "https://example.com/file.iso")
    }

    @Test("Kite deep links extract the nested URL")
    func deepLink() {
        let link = "kite://add?url=https%3A%2F%2Fexample.com%2Ffile.zip"
        #expect(DownloadURLNormalizer.normalize(link) == "https://example.com/file.zip")
    }

    @Test("Legacy deep links remain compatible")
    func legacyDeepLink() {
        let link = "superdd://add?url=https%3A%2F%2Fexample.com%2Fold.zip"
        #expect(DownloadURLNormalizer.normalize(link) == "https://example.com/old.zip")
    }

    @Test("Multiple lines ignore whitespace")
    func many() {
        let result = DownloadURLNormalizer.extractMany(from: " https://a.example/file \n\nmagnet:?xt=urn:btih:123 ")
        #expect(result == ["https://a.example/file", "magnet:?xt=urn:btih:123"])
    }

    @Test("Clipboard extraction ignores ordinary text and malformed links")
    func ignoresNonDownloadText() {
        let result = DownloadURLNormalizer.extractMany(from: """
        Remember to download this later
        www.example.com/file.zip
        https://
        magnet:?dn=missing-hash
        """)
        #expect(result.isEmpty)
    }

    @Test("Clipboard extraction accepts supported protocols and removes duplicates")
    func supportedProtocols() {
        let result = DownloadURLNormalizer.extractMany(from: """
        https://example.com/file.zip
        ftp://downloads.example.com/file.iso
        ed2k://|file|example.iso|1|0123456789ABCDEF0123456789ABCDEF|/
        magnet:?xt=urn:btih:123
        https://example.com/file.zip
        """)
        #expect(result == [
            "https://example.com/file.zip",
            "ftp://downloads.example.com/file.iso",
            "ed2k://|file|example.iso|1|0123456789ABCDEF0123456789ABCDEF|/",
            "magnet:?xt=urn:btih:123",
        ])
    }

    @Test("Analysis reports accepted, duplicate, and rejected lines")
    func analysis() {
        let result = DownloadURLNormalizer.analyze("""
        https://example.com/file.zip
        not a download
        https://example.com/file.zip
        magnet:?dn=missing-hash
        """)

        #expect(result.accepted == ["https://example.com/file.zip"])
        #expect(result.duplicateCount == 1)
        #expect(result.rejected == ["not a download", "magnet:?dn=missing-hash"])
        #expect(result.inputCount == 4)
    }
}
