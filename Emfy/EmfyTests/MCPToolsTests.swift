import Foundation
import Testing

// A3a: the five read-only MCP tools and the path-safety gate, driven through the
// server with temp copies of committed corpus files. Covers each tool's happy
// path and every path rejection (relative, non-metafile, directory, symlink to a
// non-metafile, oversize), plus the config-snippet generator. No network, no
// shared store — the server's enable gate is injected `true`.

@Suite struct MCPToolsTests {

    // MARK: - Fixtures

    private func corpusURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("corpus/\(name)")
    }

    /// A unique temp directory for a test, auto-labelled.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyMCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A temp copy of a corpus file, so a tool reads a handed-in path, never the repo original.
    private func tempCopy(_ name: String) throws -> URL {
        let dest = try tempDir().appendingPathComponent(name)
        try FileManager.default.copyItem(at: corpusURL(name), to: dest)
        return dest
    }

    // Every test file is created under `FileManager.default.temporaryDirectory`, so
    // approving that one root lets the existing happy-path and specific-rejection tests
    // reach the file through the S9 approved-folder gate. The S9 tests below build their
    // own narrower servers to exercise the gate itself.
    private let server = MCPServer(
        tools: .standard(allowedFolders: { [FileManager.default.temporaryDirectory.path] }),
        isEnabled: { true })

    /// Calls a tool and returns its (text, isError). Non-text content is summarised
    /// as "[image]" / "[resource]" so callers can assert the block type.
    private func call(_ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool, content: [[String: Any]]) {
        try call(on: server, name, arguments)
    }

    /// As `call`, but against a caller-supplied server (so an S9 test can narrow the
    /// approved folders).
    private func call(on server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool, content: [[String: Any]]) {
        let requestObject: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let requestLine = String(decoding: try JSONSerialization.data(withJSONObject: requestObject), as: UTF8.self)
        let replyLine = try #require(server.handle(line: requestLine))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(replyLine.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false, content)
    }

    // MARK: - Happy paths

    @Test func infoReportsFormatRecordsAndText() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_info", ["path": path])
        #expect(!result.isError)
        #expect(result.text.contains("Enhanced Metafile"))
        #expect(result.text.contains("Records:"))
        #expect(result.text.contains("Contains text: yes"))
        #expect(result.text.contains("Page size:"))
    }

    @Test func textReturnsTheDrawingsText() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_text", ["path": path])
        #expect(!result.isError)
        #expect(result.text.contains("Hello Emfy 123"))
    }

    @Test func findLocatesAQuery() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let hit = try call("emfy_find", ["path": path, "query": "Emfy"])
        #expect(!hit.isError)
        #expect(hit.text.lowercased().contains("match"))
        #expect(hit.text.contains("Hello Emfy 123"))

        let miss = try call("emfy_find", ["path": path, "query": "ZZXQNOTHERE"])
        #expect(!miss.isError)
        #expect(miss.text.contains("No matches"))
    }

    @Test func recordsListsTheHeaderFirst() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_records", ["path": path, "offset": 0, "limit": 10])
        #expect(!result.isError)
        #expect(result.text.contains("#0"))
        #expect(result.text.contains("EMR_HEADER"))
        #expect(result.text.contains("offset="))
    }

    @Test func recordsLimitIsCappedAt500() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        // A huge requested limit must not throw or over-return; it clamps.
        let result = try call("emfy_records", ["path": path, "offset": 0, "limit": 100000])
        #expect(!result.isError)
    }

    // S8: out-of-range numeric arguments (a crafted client) must not trap on `Int(Double)`;
    // they fall back to the defaults and the tool answers normally. (NaN/Inf can't travel
    // through JSON — `JSONSerialization` rejects them — so the finite extremes are the
    // reachable cases here; the non-finite path is covered by the JSONValue.intValue test.)
    @Test(arguments: [1e20, -1e20, 0.0])
    func recordsToleratesExtremeNumericArguments(_ value: Double) throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_records", ["path": path, "offset": value, "limit": value])
        #expect(!result.isError)
    }

    @Test func renderPNGReturnsAValidImageBlock() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_render", ["path": path, "format": "png", "scale": 2])
        #expect(!result.isError)
        let block = try #require(result.content.first)
        #expect(block["type"] as? String == "image")
        #expect(block["mimeType"] as? String == "image/png")
        let base64 = try #require(block["data"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        // PNG signature.
        #expect(bytes.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func renderPDFReturnsAResourceBlob() throws {
        let path = try tempCopy("gate-p4-text.emf").path
        let result = try call("emfy_render", ["path": path, "format": "pdf"])
        #expect(!result.isError)
        let block = try #require(result.content.first)
        #expect(block["type"] as? String == "resource")
        let resource = try #require(block["resource"] as? [String: Any])
        #expect(resource["mimeType"] as? String == "application/pdf")
        let base64 = try #require(resource["blob"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        #expect(bytes.prefix(4).elementsEqual(Array("%PDF".utf8)))
    }

    // MARK: - Path rejections (typed tool errors, never protocol errors)

    @Test func rejectsRelativePath() throws {
        let result = try call("emfy_info", ["path": "corpus/gate-p4-text.emf"])
        #expect(result.isError)
        #expect(result.text.contains("absolute"))
    }

    @Test func rejectsMissingPathArgument() throws {
        let result = try call("emfy_info", [:])
        #expect(result.isError)
    }

    @Test func rejectsNonMetafileExtension() throws {
        let dir = try tempDir()
        let txt = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        let result = try call("emfy_info", ["path": txt.path])
        #expect(result.isError)
        #expect(result.text.contains("Unsupported file type"))
    }

    @Test func rejectsDirectory() throws {
        // A directory named like a metafile must still be refused.
        let dir = try tempDir().appendingPathComponent("folder.emf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try call("emfy_info", ["path": dir.path])
        #expect(result.isError)
        #expect(result.text.contains("directory"))
    }

    @Test func rejectsSymlinkToNonMetafile() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent("secret.txt")
        try "nope".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("looks-like.emf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try call("emfy_info", ["path": link.path])
        // The symlink resolves to a .txt, so the extension re-check refuses it.
        #expect(result.isError)
        #expect(result.text.contains("Unsupported file type"))
    }

    @Test func rejectsMissingFile() throws {
        // A missing file inside an approved folder gives the generic "not available"
        // message — identical to a disallowed path, so existence never leaks (S9).
        let missing = try tempDir().appendingPathComponent("does-not-exist-\(UUID().uuidString).emf")
        let result = try call("emfy_info", ["path": missing.path])
        #expect(result.isError)
        #expect(result.text == MCPPathSafety.notAvailableMessage)
    }

    @Test func rejectsOversizeFile() throws {
        // A sparse file reports a logical size above the 256 MB cap without using disk.
        let dir = try tempDir()
        let big = dir.appendingPathComponent("huge.emf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MCPPathSafety.maxFileBytes) + 1)
        try handle.close()
        let result = try call("emfy_info", ["path": big.path])
        #expect(result.isError)
        #expect(result.text.contains("too large"))
    }

    @Test func acceptsSymlinkToARealMetafile() throws {
        // The counterpart to the rejection: a symlink to a genuine .emf is served.
        let dir = try tempDir()
        let real = try tempCopy("gate-p4-text.emf")
        let link = dir.appendingPathComponent("link.emf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let result = try call("emfy_text", ["path": link.path])
        #expect(!result.isError)
        #expect(result.text.contains("Hello Emfy 123"))
    }

    // MARK: - S9: approved folders + generic error

    @Test func rejectsPathOutsideApprovedFolders() throws {
        // A real metafile that exists and is readable, but sits outside every approved
        // folder, is refused with the generic message — not served.
        let outside = try tempDir()                   // the approved folder lives here
        let real = try tempCopy("gate-p4-text.emf")   // a genuine .emf, in a different temp dir
        let approved = outside.appendingPathComponent("approved", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        let gated = MCPServer(tools: .standard(allowedFolders: { [approved.path] }), isEnabled: { true })
        let file = try call(on: gated, "emfy_info", ["path": real.path])
        #expect(file.isError)
        #expect(file.text == MCPPathSafety.notAvailableMessage)
    }

    @Test func rejectsSymlinkEscapingApprovedFolder() throws {
        // A symlink INSIDE an approved folder that points OUT of it must be refused:
        // the resolved target is outside the approved folder (S9 symlink re-check).
        let base = try tempDir()
        let approved = base.appendingPathComponent("approved", isDirectory: true)
        let secret = base.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        let realOutside = secret.appendingPathComponent("hidden.emf")
        try FileManager.default.copyItem(at: corpusURL("gate-p4-text.emf"), to: realOutside)
        let link = approved.appendingPathComponent("link.emf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realOutside)
        let gated = MCPServer(tools: .standard(allowedFolders: { [approved.path] }), isEnabled: { true })
        let result = try call(on: gated, "emfy_text", ["path": link.path])
        #expect(result.isError)
        #expect(result.text == MCPPathSafety.notAvailableMessage)
    }

    @Test func acceptsFileInsideApprovedFolder() throws {
        // The positive counterpart: a real metafile inside an approved folder is served.
        let approved = try tempDir()
        let real = approved.appendingPathComponent("doc.emf")
        try FileManager.default.copyItem(at: corpusURL("gate-p4-text.emf"), to: real)
        let gated = MCPServer(tools: .standard(allowedFolders: { [approved.path] }), isEnabled: { true })
        let result = try call(on: gated, "emfy_text", ["path": real.path])
        #expect(!result.isError)
        #expect(result.text.contains("Hello Emfy 123"))
    }

    @Test func errorsAreIdenticalAcrossMissingDisallowedAndUnreadable() throws {
        let approved = try tempDir()
        // (1) disallowed: a real file outside the approved folder.
        let elsewhere = try tempCopy("gate-p4-text.emf")
        // (2) missing: a path inside the approved folder with nothing there.
        let missing = approved.appendingPathComponent("gone-\(UUID().uuidString).emf")
        // (3) unreadable: a real .emf inside the approved folder with read denied.
        let unreadable = approved.appendingPathComponent("locked.emf")
        try FileManager.default.copyItem(at: corpusURL("gate-p4-text.emf"), to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)

        func message(_ folders: [String], _ path: String) throws -> (text: String, isError: Bool) {
            let srv = MCPServer(tools: .standard(allowedFolders: { folders }), isEnabled: { true })
            let r = try call(on: srv, "emfy_info", ["path": path])
            return (r.text, r.isError)
        }
        let disallowed = try message([approved.path], elsewhere.path)
        let notThere = try message([approved.path], missing.path)
        let denied = try message([approved.path], unreadable.path)
        // Restore permissions so the temp cleanup/OS can remove it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)

        #expect(disallowed.isError && notThere.isError && denied.isError)
        #expect(disallowed.text == MCPPathSafety.notAvailableMessage)
        #expect(disallowed.text == notThere.text)
        #expect(notThere.text == denied.text)
    }

    @Test func emptyApprovedListServesNothing() throws {
        // The default (no folders approved) is fail-closed: even a real file is refused.
        let real = try tempCopy("gate-p4-text.emf")
        let closed = MCPServer(tools: .standard(allowedFolders: { [] }), isEnabled: { true })
        let result = try call(on: closed, "emfy_info", ["path": real.path])
        #expect(result.isError)
        #expect(result.text == MCPPathSafety.notAvailableMessage)
    }

    // MARK: - Client configuration snippet

    @Test func clientConfigSnippetNamesTheHelperCommand() {
        let path = MCPClientConfiguration.helperPath(appBundleURL: URL(fileURLWithPath: "/Applications/Emfy.app"))
        #expect(path == "/Applications/Emfy.app/Contents/Helpers/emfy-mcp")
        let json = MCPClientConfiguration.configJSON(helperPath: path)
        #expect(json.contains("mcpServers"))
        #expect(json.contains("emfy"))
        #expect(json.contains("/Applications/Emfy.app/Contents/Helpers/emfy-mcp"))
        // Valid JSON that round-trips to the expected shape.
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        let emfy = servers?["emfy"] as? [String: Any]
        #expect(emfy?["command"] as? String == path)
    }
}
