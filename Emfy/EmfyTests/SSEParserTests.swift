import Foundation
import Testing

// A2a: the pure SSE parser. Events (and single lines) may be split across chunk
// boundaries; comments and unknown fields are ignored; LF, CRLF and lone CR all
// work; malformed input never traps.

@Suite struct SSEParserTests {

    private func events(feeding chunks: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var out: [SSEEvent] = []
        for chunk in chunks { out += parser.consume(chunk) }
        if let last = parser.finish() { out.append(last) }
        return out
    }

    @Test func dispatchesNamedEventOnBlankLine() {
        let out = events(feeding: ["event: message_start\ndata: {\"a\":1}\n\n"])
        #expect(out == [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }

    @Test func splitsEventAcrossChunkBoundaries() {
        let out = events(feeding: ["event: content_bl", "ock_delta\ndata: {\"x\":", "\"hi\"}\n\n"])
        #expect(out == [SSEEvent(event: "content_block_delta", data: "{\"x\":\"hi\"}")])
    }

    @Test func splitsSingleLineAcrossBoundary() {
        // The newline itself arrives in a later chunk.
        let out = events(feeding: ["data: hello", " world\n", "\n"])
        #expect(out == [SSEEvent(event: nil, data: "hello world")])
    }

    @Test func joinsMultipleDataLines() {
        let out = events(feeding: ["data: a\ndata: b\n\n"])
        #expect(out == [SSEEvent(event: nil, data: "a\nb")])
    }

    @Test func ignoresCommentsAndUnknownFields() {
        let out = events(feeding: [": this is a comment\nid: 42\nretry: 1000\ndata: ok\n\n"])
        #expect(out == [SSEEvent(event: nil, data: "ok")])
    }

    @Test func handlesCRLFAndLoneCR() {
        let crlf = events(feeding: ["data: one\r\n\r\n"])
        #expect(crlf == [SSEEvent(event: nil, data: "one")])
        let cr = events(feeding: ["data: two\r\r"])
        #expect(cr == [SSEEvent(event: nil, data: "two")])
    }

    @Test func stripsOnlyOneLeadingSpaceAfterColon() {
        let out = events(feeding: ["data:  two-spaces\n\n"])
        #expect(out == [SSEEvent(event: nil, data: " two-spaces")])
    }

    @Test func passesDoneSentinelThroughAsData() {
        let out = events(feeding: ["data: [DONE]\n\n"])
        #expect(out == [SSEEvent(event: nil, data: "[DONE]")])
    }

    @Test func emitsMultipleEventsFromOneChunk() {
        let out = events(feeding: ["data: a\n\ndata: b\n\ndata: c\n\n"])
        #expect(out.count == 3)
        #expect(out.map(\.data) == ["a", "b", "c"])
    }

    @Test func finishFlushesTrailingEventWithoutBlankLine() {
        let out = events(feeding: ["event: message_stop\ndata: {}"])
        #expect(out == [SSEEvent(event: "message_stop", data: "{}")])
    }

    @Test(arguments: [
        "", "\n\n\n", ":::::", "data", "data:", "\r\n\r\n",
        "event\ndata\n\n", "random bytes with : colons : everywhere\n\n",
    ]) func neverTrapsOnMalformedInput(_ input: String) {
        // Any output is acceptable; the requirement is that it does not crash.
        _ = events(feeding: [input])
        #expect(Bool(true))
    }

    @Test func fuzzedByteChunksNeverTrap() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abc:\n\r {}\"data event")
        for _ in 0 ..< 200 {
            let length = Int.random(in: 0...80, using: &rng)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            // Split into random chunks.
            var parser = SSEParser()
            var remaining = Substring(text)
            while !remaining.isEmpty {
                let take = Int.random(in: 1...max(1, remaining.count), using: &rng)
                let piece = String(remaining.prefix(take))
                remaining = remaining.dropFirst(take)
                _ = parser.consume(piece)
            }
            _ = parser.finish()
        }
        #expect(Bool(true))
    }
}
