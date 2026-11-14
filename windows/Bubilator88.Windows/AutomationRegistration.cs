using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bubilator88.Windows;

/// <summary>The same client registrations offered by macOS, with commands
/// written for PowerShell. Registration text stays editable in Settings.</summary>
internal static class AutomationRegistration
{
    public sealed record Client(string Id, string Name, string Instruction);
    public static readonly Client[] Clients =
    {
        new("claudeCode", "Claude Code", "Run it in PowerShell, then start a new session."),
        new("codex", "Codex CLI", "Add it to ~/.codex/config.toml, then start a new session."),
        new("geminiCLI", "Gemini CLI", "Run it in PowerShell, then start a new session."),
        new("pi", "Pi", "Add it to ~/.pi/agent/mcp.json, then run /reload in Pi."),
        new("opencode", "opencode", "Add it to ~/.config/opencode/opencode.json, then start a new session."),
        new("vsCode", "GitHub Copilot (VS Code)", "Run it in PowerShell, then start a new session."),
        new("cursor", "Cursor", "Add it to ~/.cursor/mcp.json."),
        new("other", "Other (JSON)", "Paste it into your AI tool's MCP settings."),
    };

    public static string Create(string client, string url, string token)
    {
        string header = "Authorization: Bearer " + token;
        var headers = new JsonObject { ["Authorization"] = "Bearer " + token };
        var server = new JsonObject { ["url"] = url, ["headers"] = headers };
        switch (client)
        {
            case "claudeCode": return $"claude mcp add --scope user --transport http bubilator88 {url} --header \"{header}\"";
            case "geminiCLI": return $"gemini mcp add --scope user --transport http --header \"{header}\" bubilator88 {url}";
            case "codex": return $"[mcp_servers.bubilator88]\nurl = \"{url}\"\nhttp_headers = {{ Authorization = \"Bearer {token}\" }}";
            case "vsCode":
                server["name"] = "bubilator88"; server["type"] = "http";
                return $"code --add-mcp '{server.ToJsonString()}'";
            case "opencode":
                server["type"] = "remote";
                return Format(new JsonObject { ["$schema"] = "https://opencode.ai/config.json", ["mcp"] = new JsonObject { ["bubilator88"] = server } });
            case "pi": case "cursor": break;
            default: server["type"] = "http"; break;
        }
        return Format(new JsonObject { ["mcpServers"] = new JsonObject { ["bubilator88"] = server } });
    }

    private static string Format(JsonNode value) => value.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
}
