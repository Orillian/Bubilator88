using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class AutomationHTTPServerTests
{
    [Theory]
    [InlineData(null, null, 401)]
    [InlineData("wrong", null, 401)]
    [InlineData("secret", "https://evil.example", 403)]
    [InlineData("secret", "null", 403)]
    [InlineData("secret", null, 200)]
    public async Task Post_ValidatesCredentialsAndOrigin(string? token, string? origin, int status)
    {
        using var server = new AutomationHTTPServer(0, "secret", (body, _) => Task.FromResult<byte[]?>(body));
        server.Start();
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{server.Port}/mcp");
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (origin is not null) request.Headers.Add("Origin", origin);
        request.Content = new StringContent("{}", Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request);
        Assert.Equal(status, (int)response.StatusCode);
    }

    [Theory]
    [InlineData("GET", "/mcp", 405)]
    [InlineData("POST", "/other", 404)]
    [InlineData("POST", "/mcp", 202)]
    public async Task Request_RoutesAndAcknowledgesNotifications(string method, string path, int status)
    {
        using var server = new AutomationHTTPServer(0, "secret", (_, _) => Task.FromResult<byte[]?>(null));
        server.Start();
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var request = new HttpRequestMessage(new HttpMethod(method), $"http://127.0.0.1:{server.Port}{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "secret");
        using var response = await client.SendAsync(request);
        Assert.Equal(status, (int)response.StatusCode);
    }

    [Theory]
    [InlineData("Host: attacker.example\r\nContent-Length: 0", 403)]
    [InlineData("Host: localhost\r\nContent-Length: 1048577", 413)]
    [InlineData("Host: localhost\r\nContent-Length: -1", 400)]
    [InlineData("Host: localhost\r\nContent-Length: 0\r\nContent-Length: 0", 400)]
    [InlineData("Host: localhost\r\nTransfer-Encoding: chunked", 501)]
    public async Task Request_RejectsUnsafeOrMalformedHeaders(string headers, int status)
    {
        using var server = new AutomationHTTPServer(0, "secret", (_, _) => throw new Exception("Must not call tools."));
        server.Start();
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", server.Port);
        var stream = client.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"POST /mcp HTTP/1.1\r\n{headers}\r\nAuthorization: Bearer secret\r\n\r\n"));
        using var reader = new StreamReader(stream);
        string? response = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.StartsWith($"HTTP/1.1 {status} ", response);
    }

    [Fact]
    public async Task ConcurrentRequests_RunToolsOneAtATime()
    {
        int active = 0, maximum = 0;
        using var server = new AutomationHTTPServer(0, "secret", async (body, token) =>
        {
            int count = Interlocked.Increment(ref active);
            maximum = Math.Max(maximum, count);
            try { await Task.Delay(15, token); return body; }
            finally { Interlocked.Decrement(ref active); }
        });
        server.Start();
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "secret");
        await Task.WhenAll(Enumerable.Range(0, 8).Select(async _ =>
        {
            using var response = await client.PostAsync($"http://127.0.0.1:{server.Port}/mcp", new StringContent("{}"));
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        }));
        Assert.Equal(1, maximum);
    }

    [Fact]
    public async Task Dispose_ReleasesPortWithAnIncompleteRequest()
    {
        var server = new AutomationHTTPServer(0, "secret", (_, _) => Task.FromResult<byte[]?>(null));
        server.Start();
        int port = server.Port;
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", port);
        await client.GetStream().WriteAsync(Encoding.ASCII.GetBytes("POST /mcp HTTP/1.1\r\n"));
        server.Dispose();
        using var replacement = new AutomationHTTPServer(port, "secret", (_, _) => Task.FromResult<byte[]?>(null));
        replacement.Start();
        Assert.Equal(port, replacement.Port);
    }
}
