import Foundation

// MARK: - MCP client configuration snippet (A3a)
//
// The JSON an MCP client (Claude Desktop and the like) needs to launch Emfy's
// local server, surfaced by the Settings ▸ "MCP server" group's "Copy client
// configuration" button. Pure and Foundation-only so the app and its tests share
// one definition — the helper itself never needs it.

enum MCPClientConfiguration {
    /// The absolute path to the embedded helper inside an app bundle
    /// (`Emfy.app/Contents/Helpers/emfy-mcp`).
    static func helperPath(appBundleURL: URL) -> String {
        appBundleURL.appendingPathComponent("Contents/Helpers/emfy-mcp").path
    }

    /// The client configuration snippet for `helperPath`:
    /// `{"mcpServers": {"emfy": {"command": "<path>"}}}`. Hand-built with a fixed
    /// shape so the path's forward slashes stay unescaped and readable (unlike
    /// `JSONSerialization`, which escapes "/"), escaping only the characters JSON
    /// requires in the command string. The result is valid JSON.
    static func configJSON(helperPath: String) -> String {
        let command = escaped(helperPath)
        return """
        {
          "mcpServers": {
            "emfy": {
              "command": "\(command)"
            }
          }
        }
        """
    }

    /// Escapes a string for safe inclusion inside a JSON string literal.
    private static func escaped(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
