import Foundation
import Testing
@testable import OsXTermCore

struct ANSITextSanitizerTests {
    @Test
    func removesColorAndOSCSequences() {
        var sanitizer = ANSITextSanitizer()
        let input = "\u{001B}[32mready\u{001B}[0m\u{001B}]7;file://host/tmp\u{0007}\r\n"

        let output = sanitizer.consume(Data(input.utf8)) + sanitizer.finish()

        #expect(output == "ready\n")
    }

    @Test
    func buffersSplitEscapeSequence() {
        var sanitizer = ANSITextSanitizer()

        let first = sanitizer.consume(Data("\u{001B}[".utf8))
        let second = sanitizer.consume(Data("31merror\u{001B}[0m".utf8))

        #expect(first == "")
        #expect(second + sanitizer.finish() == "error")
    }
}
