import Foundation
import Testing
@testable import SuperDD

@Suite("Native archive post-processing")
struct PostProcessingServiceTests {
    @Test("Recognizes archive types supported by macOS tools")
    func supportedTypes() {
        #expect(PostProcessingService.isSupportedArchive(URL(fileURLWithPath: "/tmp/example.zip")))
        #expect(PostProcessingService.isSupportedArchive(URL(fileURLWithPath: "/tmp/example.tar.gz")))
        #expect(PostProcessingService.isSupportedArchive(URL(fileURLWithPath: "/tmp/example.rar")))
        #expect(PostProcessingService.isSupportedArchive(URL(fileURLWithPath: "/tmp/example.7z")))
    }
}
