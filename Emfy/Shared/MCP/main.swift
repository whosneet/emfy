import Foundation

// MARK: - emfy-mcp: stdio entry point (A3a)
//
// A local, in-house MCP server over stdio (JSON-RPC 2.0, newline-delimited). It
// reads one request per line from stdin and writes one reply per line to stdout;
// stdout carries protocol messages ONLY — all logging goes to stderr. It exposes
// five READ-ONLY tools over Emfy's clean-room parser/renderer and never writes,
// deletes, networks, or executes.
//
// Packaged only into the GitHub (DMG) app build, embedded at
// Emfy.app/Contents/Helpers/emfy-mcp, and refuses to serve tool calls until the
// user enables it in Settings (read from the shared App Group defaults).
//
// The whole loop lives in a free function so its state is function-local, not a
// main-actor-isolated top-level global; the single call below runs it.

/// The largest single request line accepted, so a client that never sends a
/// newline can't make the reader buffer grow without bound (§8).
private let maxRequestLineBytes = 16 * 1024 * 1024

func runEmfyMCPServer() {
    let server = MCPServer(tools: .standard, isEnabled: { AppGroup.mcpServerEnabled() })

    func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    func writeReply(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    logStderr("emfy-mcp \(MCPServerInfo.version): ready, read-only; "
        + "server \(AppGroup.mcpServerEnabled() ? "enabled" : "disabled") in Settings.")

    let input = FileHandle.standardInput
    var buffer = Data()

    func drainCompleteLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            if let reply = server.handle(line: line) {
                writeReply(reply)
            }
        }
        // Drop a pathologically long, newline-less buffer rather than grow forever.
        if buffer.count > maxRequestLineBytes {
            logStderr("emfy-mcp: request line exceeded \(maxRequestLineBytes) bytes; discarded.")
            buffer.removeAll(keepingCapacity: false)
        }
    }

    while true {
        let chunk = input.availableData
        if chunk.isEmpty { break }   // EOF: the client closed stdin.
        buffer.append(chunk)
        drainCompleteLines()
    }

    // A final line with no trailing newline (a client that closed stdin mid-line).
    if !buffer.isEmpty {
        let line = String(decoding: buffer, as: UTF8.self)
        if let reply = server.handle(line: line) {
            writeReply(reply)
        }
    }
}

runEmfyMCPServer()
