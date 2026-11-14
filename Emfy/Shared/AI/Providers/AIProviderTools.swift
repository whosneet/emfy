import Foundation

// MARK: - The four read-only tools for the provider path (A2a)
//
// The same four read-only tools the on-device path exposes (`DrawingAITools`),
// mapped to the HTTP providers: getDrawingText, findText, getDrawingInfo,
// listRecordTypes. They answer only from the already-extracted `DrawingAIToolData`
// snapshot — no file I/O, no network, nothing that acts (axiom-security
// agentic-security: no tool may act without user confirmation, and these cannot).
// The semantics mirror the Foundation Models tools exactly; the logic is small and
// kept in step with them, with the find path sharing `DrawingTextFind`.

enum AIProviderTools {
    /// Builds the four tools bound to one drawing's bounded snapshot.
    static func all(data: DrawingAIToolData) -> [AIProviderTool] {
        [getDrawingText(data), findText(data), getDrawingInfo(data), listRecordTypes(data)]
    }

    // MARK: getDrawingText

    private static func getDrawingText(_ data: DrawingAIToolData) -> AIProviderTool {
        AIProviderTool(
            name: "getDrawingText",
            displayName: DrawingAIToolName.getDrawingText,
            description: "Read the text in the open drawing, in reading order. Optionally start at a line and limit how many lines.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "startLine": .object([
                        "type": .string("integer"),
                        "description": .string("The 1-based line number to start from. Omit to start at the first line."),
                    ]),
                    "maxLines": .object([
                        "type": .string("integer"),
                        "description": .string("How many lines to return. Omit for a sensible default."),
                    ]),
                ]),
                "required": .array([]),
            ]),
            run: { input in
                let lines = data.textLines
                guard !lines.isEmpty else { return .ok("The drawing contains no readable text.") }
                // Clamp the 1-based line number to [1, lines.count] before the -1, so a
                // model-supplied huge or negative value can't underflow (S1).
                let startLine = min(max(1, input["startLine"]?.intValue ?? 1), lines.count)
                let start = startLine - 1
                guard start < lines.count else { return .ok("There is no text at that line.") }
                let requested = input["maxLines"]?.intValue ?? DrawingAIToolData.maxTextLinesReturned
                let count = min(max(1, requested), DrawingAIToolData.maxTextLinesReturned, lines.count - start)
                let slice = lines[start ..< (start + count)]
                let body = slice.enumerated()
                    .map { "line \(start + $0.offset + 1): \($0.element)" }
                    .joined(separator: "\n")
                // Fence the result: it carries the drawing's untrusted text (S5).
                return .ok(DrawingAIPrompt.toolResultBlock(String(body.prefix(DrawingAIToolData.maxOutputCharacters))))
            }
        )
    }

    // MARK: findText

    private static func findText(_ data: DrawingAIToolData) -> AIProviderTool {
        AIProviderTool(
            name: "findText",
            displayName: DrawingAIToolName.findText,
            description: "Find where a word, phrase, number or token appears in the open drawing's full text, and on which line. Use this whenever the user names a specific word or token or asks for a line number — the shown excerpt is partial and has no line numbers. Case- and accent-insensitive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The word or phrase to look for in the drawing's text."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
            run: { input in
                guard let query = input["query"]?.stringValue else {
                    return .error("Provide a query to search for.")
                }
                let runs = data.textLines.map {
                    DrawingTextRun(text: $0, boundsDevice: .zero, fontFamily: nil, fontSize: nil, source: .drawing)
                }
                let matches = DrawingTextFind.matches(of: query, in: runs)
                guard !matches.isEmpty else {
                    return .ok("No lines contain “\(DrawingAIContext.sanitizeLine(query))”.")
                }
                var seen = Set<Int>()
                var lines: [String] = []
                for match in matches where seen.insert(match.runIndex).inserted {
                    if data.textLines.indices.contains(match.runIndex) {
                        lines.append("line \(match.runIndex + 1): \(data.textLines[match.runIndex])")
                    }
                }
                let header = "Found \(matches.count) match\(matches.count == 1 ? "" : "es") on \(lines.count) line\(lines.count == 1 ? "" : "s"):"
                let body = ([header] + lines).joined(separator: "\n")
                // Fence the result: it carries the drawing's untrusted matched lines (S5).
                return .ok(DrawingAIPrompt.toolResultBlock(String(body.prefix(DrawingAIToolData.maxOutputCharacters))))
            }
        )
    }

    // MARK: getDrawingInfo

    private static func getDrawingInfo(_ data: DrawingAIToolData) -> AIProviderTool {
        AIProviderTool(
            name: "getDrawingInfo",
            displayName: DrawingAIToolName.getDrawingInfo,
            description: "Get the open drawing's format, page size, record count, and whether it has text or pictures.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
            ]),
            run: { _ in .ok(data.info.summary) }
        )
    }

    // MARK: listRecordTypes

    private static func listRecordTypes(_ data: DrawingAIToolData) -> AIProviderTool {
        AIProviderTool(
            name: "listRecordTypes",
            displayName: DrawingAIToolName.listRecordTypes,
            description: "List the kinds of drawing records the open drawing is made of, with how many of each.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
            ]),
            run: { _ in
                guard !data.recordCounts.isEmpty else {
                    return .ok("No record information is available for this drawing.")
                }
                let body = data.recordCounts.map { "\($0.name): \($0.count)" }.joined(separator: "\n")
                return .ok(String(("Records by kind:\n" + body).prefix(DrawingAIToolData.maxOutputCharacters)))
            }
        )
    }
}
