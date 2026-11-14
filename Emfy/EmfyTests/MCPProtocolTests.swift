import Foundation
import Testing

// A3a: the JSON-RPC 2.0 / MCP protocol core. Pure string-in, string-out tests of
// `MCPServer.handle(line:)` — framing, version negotiation, the tools/list schema,
// error codes, the no-crash-on-garbage rule, and the disabled-server gate. No I/O,
// no files; the tools themselves are covered in MCPToolsTests.

@Suite struct MCPProtocolTests {

    /// A server whose enable gate is fixed for the test.
    private func server(enabled: Bool) -> MCPServer {
        MCPServer(tools: .standard(), isEnabled: { enabled })
    }

    /// Parses a reply line into a JSON object for assertions.
    private func reply(_ line: String?) -> [String: Any]? {
        guard let line, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func request(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - initialize

    @Test func initializeReturnsServerInfoAndCapabilities() throws {
        let line = server(enabled: true).handle(line: request([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ]))
        let object = try #require(reply(line))
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 1)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "emfy")
        #expect(serverInfo["version"] != nil)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
    }

    @Test(arguments: [
        ("2025-06-18", "2025-06-18"),
        ("2025-03-26", "2025-03-26"),
        ("2024-11-05", "2024-11-05"),
        ("1999-01-01", "2025-06-18"),   // unsupported → preferred
    ])
    func negotiatesProtocolVersion(requested: String, expected: String) throws {
        let line = server(enabled: true).handle(line: request([
            "jsonrpc": "2.0", "id": 7, "method": "initialize",
            "params": ["protocolVersion": requested],
        ]))
        let result = try #require(reply(line)?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == expected)
    }

    @Test func missingProtocolVersionFallsBackToPreferred() throws {
        let line = server(enabled: true).handle(line: request([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:],
        ]))
        let result = try #require(reply(line)?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    // MARK: - notifications / ping

    @Test func initializedNotificationHasNoReply() {
        #expect(server(enabled: true).handle(line: request(["jsonrpc": "2.0", "method": "notifications/initialized"])) == nil)
    }

    @Test func requestWithoutIDIsANotificationAndGetsNoReply() {
        // A method call with no id is a notification: no reply, even for tools/list.
        #expect(server(enabled: true).handle(line: request(["jsonrpc": "2.0", "method": "tools/list"])) == nil)
    }

    @Test func pingReturnsEmptyResult() throws {
        let line = server(enabled: true).handle(line: request(["jsonrpc": "2.0", "id": "p", "method": "ping"]))
        let object = try #require(reply(line))
        #expect(object["id"] as? String == "p")
        let result = try #require(object["result"] as? [String: Any])
        #expect(result.isEmpty)
    }

    // MARK: - tools/list

    @Test func toolsListExposesTheFiveReadOnlyTools() throws {
        let line = server(enabled: true).handle(line: request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let result = try #require(reply(line)?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["emfy_info", "emfy_text", "emfy_find", "emfy_records", "emfy_render"])
        for tool in tools {
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            let required = try #require(schema["required"] as? [String])
            #expect(required.contains("path"))
        }
    }

    @Test func toolDescriptionsWarnThatContentIsUntrusted() throws {
        let line = server(enabled: true).handle(line: request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((reply(line)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        // The reading tools fence their output as untrusted data.
        for name in ["emfy_info", "emfy_text", "emfy_find", "emfy_records"] {
            let tool = try #require(tools.first { $0["name"] as? String == name })
            #expect((tool["description"] as? String)?.contains("untrusted") == true)
        }
    }

    // MARK: - errors, no crashes

    @Test func unknownMethodIsMethodNotFound() throws {
        let line = server(enabled: true).handle(line: request(["jsonrpc": "2.0", "id": 9, "method": "no/such"]))
        let error = try #require(reply(line)?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test func malformedJSONIsParseErrorWithNullID() throws {
        let line = server(enabled: true).handle(line: "{ this is not json ")
        let object = try #require(reply(line))
        #expect(object["id"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
    }

    @Test func nonObjectJSONIsInvalidRequest() throws {
        // Valid JSON that isn't an object (a request must be an object) → -32600.
        let line = server(enabled: true).handle(line: "[1, 2, 3]")
        let error = try #require(reply(line)?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32600)
    }

    @Test func blankLineProducesNoReply() {
        #expect(server(enabled: true).handle(line: "   ") == nil)
        #expect(server(enabled: true).handle(line: "") == nil)
    }

    @Test(arguments: ["", "null", "[]", "{}", "{\"jsonrpc\":\"2.0\"}", "\"hello\"", "{\"id\":5}"])
    func hostileLinesNeverCrash(_ line: String) {
        // The contract is only "does not trap"; any defined reply (or nil) is fine.
        _ = server(enabled: true).handle(line: line)
    }

    // MARK: - disabled gate

    @Test func disabledServerStillAnswersDiscovery() throws {
        let s = server(enabled: false)
        #expect(reply(s.handle(line: request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]]))) != nil)
        let list = try #require(reply(s.handle(line: request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))))
        #expect((list["result"] as? [String: Any])?["tools"] != nil)
    }

    @Test func disabledServerRefusesToolCallsWithAFriendlyError() throws {
        let s = server(enabled: false)
        let line = s.handle(line: request([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "emfy_info", "arguments": ["path": "/tmp/whatever.emf"]],
        ]))
        let result = try #require(reply(line)?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = content.first?["text"] as? String ?? ""
        #expect(text.contains("Enable the MCP server"))
    }

    @Test func unknownToolNameIsAnErrorResultNotAProtocolError() throws {
        let line = server(enabled: true).handle(line: request([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "emfy_delete_everything", "arguments": [:]],
        ]))
        let object = try #require(reply(line))
        #expect(object["error"] == nil)   // not a JSON-RPC protocol error
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }
}
