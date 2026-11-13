import Foundation

// MARK: - MCP over stdio: JSON-RPC 2.0 core (A3a)
//
// The transport-agnostic, pure heart of Emfy's in-house MCP server. It parses one
// newline-delimited JSON-RPC 2.0 message, routes it, and produces the exact bytes
// to write back (or `nil` for a notification, which gets no reply). It never
// crashes on hostile input: a parse failure is a JSON-RPC error, not a trap.
//
// Everything here is Foundation-only and free of I/O, so the whole protocol is
// unit-testable by feeding `handle(line:)` a string and asserting on the reply.
// The stdio read/write loop and the concrete tools live in their own files.
//
// Design (owner, A3a): stdout carries protocol messages ONLY; logs go to stderr.

/// The JSON-RPC 2.0 error codes this server emits ([JSON-RPC 2.0] §5.1).
enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// The MCP protocol versions this server understands. `initialize` echoes the
/// client's requested version when it is one of these, else falls back to the
/// newest (`preferred`). Order is newest-first for readability only.
enum MCPProtocolVersion {
    static let preferred = "2025-06-18"
    static let supported: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Negotiates the version to report back: the client's choice when supported,
    /// otherwise `preferred`.
    static func negotiate(requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return preferred }
        return requested
    }
}

/// Identity reported in `initialize`.
enum MCPServerInfo {
    static let name = "emfy"
    /// Kept in step with the app's MARKETING_VERSION; the helper has no Info.plist
    /// to read it from, so it is a constant here.
    static let version = "3.0"
}

/// The server: given a tool registry and an enable-gate closure, it turns one
/// request line into one reply line. The stdio loop drives it on one thread, so
/// it keeps no concurrency guarantees and holds no mutable state of its own.
struct MCPServer {
    /// The tools exposed through `tools/list` and `tools/call`.
    let tools: MCPToolRegistry
    /// Whether tool calls are permitted right now. Read fresh on every
    /// `tools/call` so toggling the Settings switch takes effect without a
    /// restart. `initialize` / `tools/list` ignore it (so a client can always
    /// discover the server).
    let isEnabled: () -> Bool
    /// The message shown when a tool is called while the server is disabled.
    static let disabledMessage = "Enable the MCP server in Emfy Settings (the “MCP server” group) to let it read drawings."

    init(tools: MCPToolRegistry, isEnabled: @escaping () -> Bool) {
        self.tools = tools
        self.isEnabled = isEnabled
    }

    /// Handles one raw request line. Returns the reply line (no trailing newline)
    /// or `nil` when nothing should be written (a notification, or a blank line).
    func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return errorReply(id: NSNull(), code: MCPErrorCode.parseError, message: "Parse error")
        }
        guard let request = object as? [String: Any] else {
            // A JSON value that isn't an object can't be a request.
            return errorReply(id: NSNull(), code: MCPErrorCode.invalidRequest, message: "Invalid request")
        }

        // `id` absent ⇒ notification ⇒ no reply, even on error. Present ⇒ echo it
        // verbatim (string, number, or null) in the reply.
        let hasID = request.index(forKey: "id") != nil
        let id = request["id"] ?? NSNull()

        guard let method = request["method"] as? String else {
            return hasID ? errorReply(id: id, code: MCPErrorCode.invalidRequest, message: "Invalid request: missing method") : nil
        }

        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return hasID ? resultReply(id: id, result: initializeResult(params: params)) : nil
        case "notifications/initialized", "notifications/cancelled":
            // Notifications: acknowledged by doing nothing and replying nothing.
            return nil
        case "ping":
            return hasID ? resultReply(id: id, result: [:]) : nil
        case "tools/list":
            return hasID ? resultReply(id: id, result: ["tools": tools.listSchema()]) : nil
        case "tools/call":
            guard hasID else { return nil }   // a call with no id can't receive its result
            return resultReply(id: id, result: toolsCallResult(params: params))
        default:
            return hasID ? errorReply(id: id, code: MCPErrorCode.methodNotFound, message: "Method not found: \(method)") : nil
        }
    }

    // MARK: - Method handlers

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        return [
            "protocolVersion": MCPProtocolVersion.negotiate(requested: requested),
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": MCPServerInfo.name, "version": MCPServerInfo.version],
        ]
    }

    private func toolsCallResult(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return MCPToolResult.error("A tool call needs a \"name\".").asDictionary
        }
        // Disabled gate: discovery always works, but no drawing is read until the
        // user opts in (agentic-security: no tool acts without consent).
        guard isEnabled() else {
            return MCPToolResult.error(Self.disabledMessage).asDictionary
        }
        guard let tool = tools.tool(named: name) else {
            return MCPToolResult.error("Unknown tool: \(name)").asDictionary
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return tool.call(arguments).asDictionary
    }

    // MARK: - Reply framing

    private func resultReply(id: Any, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorReply(id: Any, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Serialises a reply object to a single compact JSON line. Returns a
    /// hand-built internal-error line if serialisation somehow fails, so the
    /// server never drops a reply it owes a client an answer to.
    private func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return string
    }
}
