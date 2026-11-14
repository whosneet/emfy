import EMFRender
import Foundation
import FoundationModels

// MARK: - Read-only drawing tools for the model (A1a)
//
// Four Foundation Models `Tool`s that let the model GROUND its answers in the open
// drawing. They are strictly read-only: each only reads from `DrawingAIToolData`,
// a value snapshot of the already-loaded drawing. No file I/O beyond it, no
// network, nothing that mutates or acts (there are no actions in A1a — axiom-
// security agentic-security: no tool may act without user confirmation, and these
// simply cannot act). The tools never re-interpret a metafile: the text and facts
// were extracted once by the viewer.
//
// Each tool records that it was used, so the Ask UI can show a "Used: …" footnote.

/// Records which tools the model used during one answer, in first-use order. The
/// tools run off the main actor (`Tool.call` is `@concurrent`), so this is a small
/// lock-guarded collector rather than an actor (which `call` can't await inline).
final class DrawingAIToolUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var total = 0
    private var outputChars = 0

    /// The per-turn TOTAL tool-output budget, in characters (FM-1): the sum of every
    /// tool result in one answer is capped, on top of each tool's own per-call limit,
    /// so a model that calls tools repeatedly — or a "dump everything" injection — can't
    /// flood and overflow the context window with tool output.
    static let maxTotalOutputCharacters = 12_000

    /// Records `name` once for display (first-use order preserved), and counts every
    /// call including repeats (so a "call findText 1000 times" injection is detectable).
    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        total += 1
        if !names.contains(name) { names.append(name) }
    }

    /// The display names of the tools used so far, in first-use order.
    func used() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    /// The total number of tool calls, including repeats of the same tool.
    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// Applies a tool result's own `perCallLimit`, then the per-turn TOTAL output budget,
    /// recording what it consumed (FM-1). Once the turn's budget is spent it returns a
    /// short note, so the model gets a clear signal instead of silently truncated data.
    func takeOutputBudget(_ body: String, perCallLimit: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let remaining = Self.maxTotalOutputCharacters - outputChars
        guard remaining > 0 else { return "(Tool output limit for this answer reached; no more can be returned.)" }
        let perCall = String(body.prefix(perCallLimit))
        let allowed = String(perCall.prefix(remaining))
        outputChars += allowed.count
        return allowed
    }

    /// Clears the record before a new answer.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        names.removeAll(keepingCapacity: true)
        total = 0
        outputChars = 0
    }
}

/// The read-only snapshot the tools answer from: the drawing's text in reading
/// order, its structured info, and its record-kind counts. A pure value type
/// (plus the `Sendable` usage recorder), so tests build it from a fixture and call
/// each tool directly, with no live model.
struct DrawingAIToolData: Sendable {
    /// The drawing's text runs, in reading order, already sanitised.
    var textLines: [String]
    /// Structured facts (format, page size, record count, has text/pictures).
    var info: DrawingInfo
    /// Record-kind counts (name, count), most-frequent-first.
    var recordCounts: [(name: String, count: Int)]
    /// The shared usage recorder (shared with the session's tools).
    var usage: DrawingAIToolUsage

    init(
        textLines: [String],
        info: DrawingInfo,
        recordKinds: [MetafileRenderer.RecordKindCount],
        usage: DrawingAIToolUsage = DrawingAIToolUsage()
    ) {
        self.textLines = textLines
        self.info = info
        let sortedKinds = recordKinds.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.name < b.name
        }
        self.recordCounts = sortedKinds.map { ($0.name, $0.count) }
        self.usage = usage
    }

    /// How many text lines a tool call will return at most, so a huge all-text file
    /// doesn't flood the model.
    static let maxTextLinesReturned = 200
    /// The longest tool output, in characters.
    static let maxOutputCharacters = 4000
}

// MARK: - Tool display names (shown in the "Used:" footnote; asserted in tests)

enum DrawingAIToolName {
    static let getDrawingText = "Read text"
    static let findText = "Find text"
    static let getDrawingInfo = "Drawing info"
    static let listRecordTypes = "Record types"

    /// Every tool's display name, for the read-only assertion.
    static let all = [getDrawingText, findText, getDrawingInfo, listRecordTypes]
}

// MARK: - Tools

/// Returns a slice of the drawing's text in reading order.
@available(macOS 26, iOS 26, *)
struct GetDrawingTextTool: Tool {
    let name = "getDrawingText"
    let description = "Read the text in the open drawing, in reading order. Optionally start at a line and limit how many lines."
    let data: DrawingAIToolData

    @Generable
    struct Arguments {
        @Guide(description: "The 1-based line number to start from. Omit to start at the first line.")
        var startLine: Int?
        @Guide(description: "How many lines to return. Omit for a sensible default.")
        var maxLines: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        data.usage.record(DrawingAIToolName.getDrawingText)
        let lines = data.textLines
        guard !lines.isEmpty else { return "The drawing contains no readable text." }
        // Clamp the 1-based line number to [1, lines.count] before the -1, so a
        // model-supplied huge or negative value can't underflow (S1).
        let startLine = min(max(1, arguments.startLine ?? 1), lines.count)
        let start = startLine - 1
        guard start < lines.count else { return "There is no text at that line." }
        let requested = arguments.maxLines ?? DrawingAIToolData.maxTextLinesReturned
        let count = min(max(1, requested), DrawingAIToolData.maxTextLinesReturned, lines.count - start)
        let slice = lines[start ..< (start + count)]
        let body = slice.enumerated()
            .map { "line \(start + $0.offset + 1): \($0.element)" }
            .joined(separator: "\n")
        // Fence the result: it carries the drawing's untrusted text (S5). The per-call
        // limit and the per-turn total budget both apply (FM-1).
        return DrawingAIPrompt.toolResultBlock(data.usage.takeOutputBudget(body, perCallLimit: DrawingAIToolData.maxOutputCharacters))
    }
}

/// Finds which lines of the drawing's text contain a query.
@available(macOS 26, iOS 26, *)
struct FindTextTool: Tool {
    let name = "findText"
    let description = "Find where a word, phrase, number or token appears in the open drawing's full text, and on which line. Use this whenever the user names a specific word or token or asks for a line number — the shown excerpt is partial and has no line numbers. Case- and accent-insensitive."
    let data: DrawingAIToolData

    @Generable
    struct Arguments {
        @Guide(description: "The word or phrase to look for in the drawing's text.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        data.usage.record(DrawingAIToolName.findText)
        let runs = data.textLines.map {
            DrawingTextRun(text: $0, boundsDevice: .zero, fontFamily: nil, fontSize: nil, source: .drawing)
        }
        let matches = DrawingTextFind.matches(of: arguments.query, in: runs)
        guard !matches.isEmpty else {
            return "No lines contain “\(DrawingAIContext.sanitizeLine(arguments.query))”."
        }
        // Report the matching lines (in reading order), de-duplicated by line.
        var seen = Set<Int>()
        var lines: [String] = []
        for match in matches where seen.insert(match.runIndex).inserted {
            if data.textLines.indices.contains(match.runIndex) {
                lines.append("line \(match.runIndex + 1): \(data.textLines[match.runIndex])")
            }
        }
        let header = "Found \(matches.count) match\(matches.count == 1 ? "" : "es") on \(lines.count) line\(lines.count == 1 ? "" : "s"):"
        let body = ([header] + lines).joined(separator: "\n")
        // Fence the result: it carries the drawing's untrusted matched lines (S5). The
        // per-call limit and the per-turn total budget both apply (FM-1).
        return DrawingAIPrompt.toolResultBlock(data.usage.takeOutputBudget(body, perCallLimit: DrawingAIToolData.maxOutputCharacters))
    }
}

/// Returns the drawing's structured info.
@available(macOS 26, iOS 26, *)
struct GetDrawingInfoTool: Tool {
    let name = "getDrawingInfo"
    let description = "Get the open drawing's format, page size, record count, and whether it has text or pictures."
    let data: DrawingAIToolData

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        data.usage.record(DrawingAIToolName.getDrawingInfo)
        return data.usage.takeOutputBudget(data.info.summary, perCallLimit: DrawingAIToolData.maxOutputCharacters)
    }
}

/// Lists the kinds of records the drawing is made of, with counts.
@available(macOS 26, iOS 26, *)
struct ListRecordTypesTool: Tool {
    let name = "listRecordTypes"
    let description = "List the kinds of drawing records the open drawing is made of, with how many of each."
    let data: DrawingAIToolData

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        data.usage.record(DrawingAIToolName.listRecordTypes)
        guard !data.recordCounts.isEmpty else { return "No record information is available for this drawing." }
        let body = data.recordCounts.map { "\($0.name): \($0.count)" }.joined(separator: "\n")
        return data.usage.takeOutputBudget("Records by kind:\n" + body, perCallLimit: DrawingAIToolData.maxOutputCharacters)
    }
}

enum DrawingAITools {
    /// The four read-only tools, bound to one drawing's data (sharing its usage
    /// recorder). The ONLY tools A1a exposes — all read-only, none acts.
    @available(macOS 26, iOS 26, *)
    static func all(data: DrawingAIToolData) -> [any Tool] {
        [
            GetDrawingTextTool(data: data),
            FindTextTool(data: data),
            GetDrawingInfoTool(data: data),
            ListRecordTypesTool(data: data),
        ]
    }
}
