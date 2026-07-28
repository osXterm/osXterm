import Foundation
import Testing
@testable import OsXTermCore

@Suite
struct OSC7PathTrackerTests {
    @Test
    func testTracksPercentDecodedPathAcrossEveryChunkBoundary() {
        let sequence = Data(
            "\u{001B}]7;file://server.example.com/Users/dev/My%20Project\u{0007}".utf8
        )

        for splitIndex in 0 ... sequence.count {
            var tracker = OSC7PathTracker()
            let first = tracker.ingest(sequence.prefix(splitIndex))
            let second = tracker.ingest(sequence.dropFirst(splitIndex))
            let updates = first + second

            #expect(updates.count == 1, "split index \(splitIndex)")
            #expect(updates.first?.host == "server.example.com")
            #expect(updates.first?.path == "/Users/dev/My Project")
        }
    }

    @Test
    func testRecognizesSplitStringTerminatorAndIgnoresOtherOSCCommands() {
        var tracker = OSC7PathTracker()

        let first = tracker.ingest(
            Data("\u{001B}]0;window title\u{0007}\u{001B}]7;file:///srv/app\u{001B}".utf8)
        )
        let second = tracker.ingest(Data("\\".utf8))

        #expect(first.isEmpty)
        #expect(second.map(\.path) == ["/srv/app"])
        #expect(second.first?.host == nil)
    }

    @Test
    func testRecognizesEightBitOSCAndStringTerminator() {
        var tracker = OSC7PathTracker()
        var bytes: [UInt8] = [0x9D]
        bytes += Array("7;file://host.example/var/log".utf8)
        bytes.append(0x9C)

        let updates = tracker.ingest(bytes)

        #expect(updates.map(\.host) == ["host.example"])
        #expect(updates.map(\.path) == ["/var/log"])
    }

    @Test
    func testDiscardsOversizedPayloadThenRecovers() {
        var tracker = OSC7PathTracker(maximumPayloadBytes: 16)
        let oversized = Data(
            ("\u{001B}]7;file://host/" + String(repeating: "a", count: 64) + "\u{0007}").utf8
        )
        let valid = Data("\u{001B}]7;file:///ok\u{0007}".utf8)

        #expect(tracker.ingest(oversized).isEmpty)
        #expect(tracker.ingest(valid).map(\.path) == ["/ok"])
    }

    @Test
    func testRejectsNonFileAndInvalidUTF8Payloads() {
        var tracker = OSC7PathTracker()
        var invalidUTF8: [UInt8] = Array("\u{001B}]7;file:///".utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8.append(0x07)

        let nonFile = tracker.ingest(Data("\u{001B}]7;https://example.com/path\u{0007}".utf8))
        let invalid = tracker.ingest(invalidUTF8)

        #expect(nonFile.isEmpty)
        #expect(invalid.isEmpty)
    }
}
