using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Bubilator88.Windows.Tests;

/// <summary>Opt-in tests against the actual Swift DLL, including reverse P/Invoke.
/// Set B88_MCP_TEST_DLL to an absolute path and put Swift runtime DLLs on PATH.</summary>
public sealed class NativeMcpFactAttribute : FactAttribute
{
    public NativeMcpFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("B88_MCP_TEST_DLL")))
            Skip = "Set B88_MCP_TEST_DLL to run the native MCP integration tests.";
    }
}

public sealed class AutomationSessionTests
{
    static AutomationSessionTests() => NativeMcpLibrary.Initialize();

    private sealed class Commands : IEmulatorAppCommands
    {
        public bool IsRunning { get; private set; } = true;
        public int Publishes;
        public void SetRunning(bool running) => IsRunning = running;
        public void PublishFrame() => Publishes++;
        public void Reset(EmulatorBootMode? mode, bool? clock8MHz) => throw new InvalidOperationException("Host command refused for testing.");
        public string MountDisk(int drive, string path, int imageIndex, bool writeProtected) => "Disk name";
        public void EjectDisk(int drive) { }
        public void SaveState(string path) { }
        public void LoadState(string path) { }
    }

    [NativeMcpFact]
    public async Task Http_RoundTripsThroughNativeAppHost()
    {
        IntPtr machine = NativeApi.b88_create();
        var commands = new Commands();
        int frames = 0;
        var sync = new object();
        var host = new AppAutomationHost(commands, action => { lock (sync) action(); },
            (before, token) =>
            {
                lock (sync)
                {
                    if (commands.IsRunning || !before()) return false;
                    NativeApi.b88_run_frame(machine); frames++; return true;
                }
            }, new AutomationUiDispatcher(action => { action(); return true; }));
        try
        {
            await using var session = new AutomationSession(
                (callbacks, version) => NativeApi.CreateAppMcpSession(machine, callbacks, version), "test-version", host);
            using var server = new AutomationHTTPServer(0, "secret", session.HandleAsync);
            server.Start();
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "secret");
            async Task<JsonNode> Send(string method, JsonObject? parameters = null)
            {
                var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = 42, ["method"] = method, ["params"] = parameters };
                using var response = await client.PostAsync($"http://127.0.0.1:{server.Port}/mcp",
                    new StringContent(request.ToJsonString(), Encoding.UTF8, "application/json"));
                response.EnsureSuccessStatusCode();
                return JsonNode.Parse(await response.Content.ReadAsStringAsync())!;
            }
            var initialized = await Send("initialize");
            Assert.Equal("test-version", initialized["result"]!["serverInfo"]!["version"]!.GetValue<string>());
            await Send("ping");
            await Send("tools/list");
            Assert.Equal(0, commands.Publishes);
            var status = await Send("tools/call", new JsonObject { ["name"] = "status" });
            Assert.True(JsonNode.Parse(status["result"]!["content"]![0]!["text"]!.GetValue<string>())!["real_time"]!.GetValue<bool>());
            await Send("tools/call", new JsonObject { ["name"] = "run_frames", ["arguments"] = new JsonObject { ["frames"] = 3 } });
            Assert.False(commands.IsRunning);
            Assert.Equal(3, frames);
            Assert.Equal(1, commands.Publishes);
            await Send("tools/call", new JsonObject { ["name"] = "resume" });
            Assert.True(commands.IsRunning);
            var error = await Send("tools/call", new JsonObject { ["name"] = "reset" });
            Assert.True(error["result"]!["isError"]!.GetValue<bool>());
            Assert.Equal("Host command refused for testing.", error["result"]!["content"]![0]!["text"]!.GetValue<string>());
        }
        finally { NativeApi.b88_destroy(machine); }
    }

    [NativeMcpFact]
    public async Task Dispose_CancelsQueuedUiCallbackBeforeDestroyingSession()
    {
        IntPtr machine = NativeApi.b88_create();
        using var entered = new ManualResetEventSlim();
        Action? queued = null;
        var host = new AppAutomationHost(new Commands(), action => action(), (_, _) => false,
            new AutomationUiDispatcher(action => { queued = action; entered.Set(); return true; }));
        try
        {
            var session = new AutomationSession(
                (callbacks, version) => NativeApi.CreateAppMcpSession(machine, callbacks, version), "test", host);
            var request = session.HandleAsync(Encoding.UTF8.GetBytes("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"pause\"}}"), CancellationToken.None);
            Assert.True(entered.Wait(TimeSpan.FromSeconds(10)));
            await session.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            await request;
            queued!(); // A canceled UI callback must not use the destroyed native session.
            await session.DisposeAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.HandleAsync(Encoding.UTF8.GetBytes("{}"), CancellationToken.None));
        }
        finally { NativeApi.b88_destroy(machine); }
    }
}
