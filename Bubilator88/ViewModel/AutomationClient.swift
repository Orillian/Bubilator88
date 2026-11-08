import Foundation

/// The MCP clients Settings writes a registration for: what to run or add to
/// connect each to the AI tools server, and where it goes.
///
/// Clients change their command-line syntax and file formats, so Settings
/// shows the text editable; when one has moved on, the user fixes it there
/// and this table catches up later.
enum AutomationClient: String, CaseIterable, Identifiable {
  case claudeCode, codex, geminiCLI, pi, opencode
  case vsCode, cursor
  case other

  var id: String { rawValue }

  static let terminal: [AutomationClient] = [.claudeCode, .codex, .geminiCLI, .pi, .opencode]
  static let editors: [AutomationClient] = [.vsCode, .cursor]

  /// Product names stay as they are; only the catch-all is translated.
  var name: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex CLI"
    case .geminiCLI: "Gemini CLI"
    case .pi: "Pi"
    case .opencode: "opencode"
    case .vsCode: "GitHub Copilot (VS Code)"
    case .cursor: "Cursor"
    case .other: String(localized: "Other (JSON)", comment: "AI tool picker: any MCP client, given the settings as JSON")
    }
  }

  /// The command to run, or the settings to add, for the server at `url`.
  func registration(url: String, token: String) -> String {
    let header = "Authorization: Bearer \(token)"
    let headers = "{ \"Authorization\": \"Bearer \(token)\" }"
    switch self {
    case .claudeCode:
      return """
      claude mcp add --scope user --transport http bubilator88 \\
        \(url) \\
        --header "\(header)"
      """
    case .geminiCLI:
      return """
      gemini mcp add --scope user --transport http \\
        --header "\(header)" \\
        bubilator88 \(url)
      """
    case .vsCode:
      return """
      code --add-mcp '{"name": "bubilator88", "type": "http", "url": "\(url)", "headers": \(headers)}'
      """
    case .codex:
      return """
      [mcp_servers.bubilator88]
      url = "\(url)"
      http_headers = \(headers.replacingOccurrences(of: "\": ", with: "\" = "))
      """
    case .opencode:
      return """
      {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {
          "bubilator88": {
            "type": "remote",
            "url": "\(url)",
            "headers": \(headers)
          }
        }
      }
      """
    case .pi, .cursor:
      return Self.mcpServers(url: url, headers: headers, type: nil)
    case .other:
      return Self.mcpServers(url: url, headers: headers, type: "http")
    }
  }

  /// One sentence on where the registration goes.
  var instruction: String {
    switch self {
    case .claudeCode, .geminiCLI, .vsCode:
      String(localized: "Run it in Terminal, then start a new session.", comment: "AI tool registration: how to use a command")
    case .codex:
      String(localized: "Add it to ~/.codex/config.toml, then start a new session.", comment: "AI tool registration for Codex CLI")
    case .pi:
      String(localized: "Add it to ~/.pi/agent/mcp.json, then run /reload in Pi.", comment: "AI tool registration for Pi")
    case .opencode:
      String(localized: "Add it to ~/.config/opencode/opencode.json, then start a new session.", comment: "AI tool registration for opencode")
    case .cursor:
      String(localized: "Add it to ~/.cursor/mcp.json.", comment: "AI tool registration for Cursor")
    case .other:
      String(localized: "Paste it into your AI tool's MCP settings, or ask the AI to add it.", comment: "AI tool registration for any other MCP client")
    }
  }

  /// The `mcpServers` form most clients' settings files take.
  private static func mcpServers(url: String, headers: String, type: String?) -> String {
    let typeLine = type.map { "\n      \"type\": \"\($0)\"," } ?? ""
    return """
    {
      "mcpServers": {
        "bubilator88": {\(typeLine)
          "url": "\(url)",
          "headers": \(headers)
        }
      }
    }
    """
  }
}
