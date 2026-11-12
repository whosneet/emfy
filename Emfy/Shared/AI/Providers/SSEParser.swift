import Foundation

// MARK: - Server-Sent Events parser (A2a)
//
// A pure, incremental SSE parser for both wire formats (Anthropic's named events
// and OpenAI's `data:`-only chunks). It is fed arbitrary byte chunks — events and
// even single lines may be split across chunk boundaries — and yields complete
// events. It never traps on malformed input: unknown fields are ignored, comment
// lines (`:`) are dropped, and CR, LF and CRLF line endings are all accepted
// (W3C SSE). Splitting happens at the BYTE level (LF/CR are ASCII and never
// divide a UTF-8 codepoint); it must not split on Swift `Character`s, because a
// CRLF is a single grapheme and would be missed. Dispatch happens on a blank
// line; `finish()` flushes any trailing event a stream ended without one.

/// One dispatched SSE event: the optional `event:` name and the joined `data:`
/// payload (multiple data lines joined by "\n", per the SSE spec).
struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental SSE parser. A value type driven within a single consuming task.
struct SSEParser {
    private var pending: [UInt8] = []
    private var eventType: String?
    private var dataLines: [String] = []
    private var sawData = false
    /// Whether the previous byte was a CR, so a following LF (the CRLF pair) does
    /// not open a second, empty line.
    private var lastWasCR = false

    /// Feeds a chunk of decoded text, returning any events completed by it.
    mutating func consume(_ text: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in text.utf8 {
            if let event = consume(byte: byte) { events.append(event) }
        }
        return events
    }

    /// Feeds one raw byte, returning an event if the byte closed a pending one.
    /// CR and LF both terminate a line; a CRLF pair terminates exactly one.
    mutating func consume(byte: UInt8) -> SSEEvent? {
        switch byte {
        case 0x0D: // CR terminates the line.
            let event = endLine()
            lastWasCR = true
            return event
        case 0x0A: // LF: the second half of a CRLF is swallowed, else it terminates.
            if lastWasCR {
                lastWasCR = false
                return nil
            }
            return endLine()
        default:
            lastWasCR = false
            pending.append(byte)
            return nil
        }
    }

    /// Feeds exactly one already-split line (no newline). Used where the caller has
    /// already split on newlines.
    mutating func consumeLine(_ line: String) -> SSEEvent? {
        process(line: line)
    }

    /// Flushes any event accumulated without a terminating newline. Call once when
    /// the stream ends.
    mutating func finish() -> SSEEvent? {
        if !pending.isEmpty {
            _ = process(line: decodePending())
            pending.removeAll(keepingCapacity: true)
        }
        return dispatch()
    }

    // MARK: Line handling

    private mutating func endLine() -> SSEEvent? {
        let line = decodePending()
        pending.removeAll(keepingCapacity: true)
        return process(line: line)
    }

    private func decodePending() -> String { String(decoding: pending, as: UTF8.self) }

    /// Processes one line (newline already stripped). Returns an event on a blank
    /// line that closes a pending event.
    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // comment
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines.append(String(value))
            sawData = true
        default:
            break // id, retry, unknown — ignored
        }
        return nil
    }

    /// Emits the accumulated event (if any) and resets for the next.
    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            dataLines.removeAll(keepingCapacity: true)
            sawData = false
        }
        guard sawData || eventType != nil else { return nil }
        return SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"))
    }
}
