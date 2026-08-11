import Foundation
import Testing
@testable import SuperDD

@Suite("Download URL normalization")
struct DownloadURLNormalizerTests {
    @Test("Thunder links decode their AA and ZZ envelope")
    func thunder() {
        let wrapped = "AAhttps://example.com/file.isoZZ"
        let encoded = Data(wrapped.utf8).base64EncodedString()
        #expect(DownloadURLNormalizer.normalize("thunder://\(encoded)") == "https://example.com/file.iso")
    }

    @Test("Super DD deep links extract the nested URL")
    func deepLink() {
        let link = "superdd://add?url=https%3A%2F%2Fexample.com%2Ffile.zip"
        #expect(DownloadURLNormalizer.normalize(link) == "https://example.com/file.zip")
    }

    @Test("Multiple lines ignore whitespace")
    func many() {
        let result = DownloadURLNormalizer.extractMany(from: " https://a.example/file \n\nmagnet:?xt=urn:btih:123 ")
        #expect(result == ["https://a.example/file", "magnet:?xt=urn:btih:123"])
    }
}
