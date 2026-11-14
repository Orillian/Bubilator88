using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Bubilator88.Windows;

/// <summary>Loopback-only MCP Streamable HTTP transport. Tool calls are serialized;
/// GET/SSE is not offered. Uses TCP directly so no HTTP.sys URL reservation is needed.</summary>
internal sealed class AutomationHTTPServer : IDisposable
{
    private const int MaxHeader = 16 * 1024, MaxBody = 1024 * 1024;
    private readonly TcpListener _listener;
    private readonly byte[] _authorization;
    private readonly Func<byte[], CancellationToken, Task<byte[]?>> _handle;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _calls = new(1);
    private readonly ConcurrentDictionary<TcpClient, byte> _clients = new();
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
    public event Action<string>? Failed;

    public AutomationHTTPServer(int port, string token, Func<byte[], CancellationToken, Task<byte[]?>> handle)
    {
        _listener = new TcpListener(IPAddress.Loopback, port);
        _authorization = Encoding.UTF8.GetBytes("Bearer " + token);
        _handle = handle;
    }

    public void Start()
    {
        _listener.Start();
        _ = AcceptAsync();
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(_stop.Token).ConfigureAwait(false);
                _clients.TryAdd(client, 0);
                _ = ServeAsync(client);
            }
        }
        catch (Exception ex) when (_stop.IsCancellationRequested || ex is SocketException)
        {
            if (!_stop.IsCancellationRequested) Failed?.Invoke(ex.Message);
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token))
        {
            try
            {
                var stream = client.GetStream();
                while (!_stop.IsCancellationRequested)
                {
                    // Bound incomplete requests as well as their size. Long tool calls
                    // have no transport timeout; only receiving a request does.
                    timeout.CancelAfter(TimeSpan.FromSeconds(30));
                    var head = new List<byte>();
                    var one = new byte[1];
                    while (head.Count < 4 || !(head[^4] == 13 && head[^3] == 10 && head[^2] == 13 && head[^1] == 10))
                    {
                        if (head.Count >= MaxHeader) { await SendAsync(stream, 431, null, timeout.Token); return; }
                        if (await stream.ReadAsync(one, timeout.Token).ConfigureAwait(false) == 0) return;
                        head.Add(one[0]);
                    }
                    var lines = Encoding.ASCII.GetString(head.ToArray()).Split("\r\n");
                    var first = lines[0].Split(' ');
                    if (first.Length != 3 || first[2] != "HTTP/1.1") { await SendAsync(stream, 400, null, timeout.Token); return; }
                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 1; i < lines.Length && lines[i].Length > 0; i++)
                    {
                        int colon = lines[i].IndexOf(':');
                        if (colon <= 0 || !headers.TryAdd(lines[i][..colon], lines[i][(colon + 1)..].Trim()))
                        { await SendAsync(stream, 400, null, timeout.Token); return; }
                    }
                    int refusal = Refusal(headers);
                    if (refusal != 0) { await SendAsync(stream, refusal, null, timeout.Token); return; }
                    if (headers.ContainsKey("Transfer-Encoding")) { await SendAsync(stream, 501, null, timeout.Token); return; }
                    int length = 0;
                    if (headers.TryGetValue("Content-Length", out var raw) &&
                        !int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out length))
                    { await SendAsync(stream, 400, null, timeout.Token); return; }
                    if (length > MaxBody) { await SendAsync(stream, 413, null, timeout.Token); return; }
                    var body = new byte[length];
                    await stream.ReadExactlyAsync(body, timeout.Token).ConfigureAwait(false);
                    timeout.CancelAfter(Timeout.InfiniteTimeSpan);
                    var path = first[1].Split('?')[0];
                    int status;
                    byte[]? reply = null;
                    if (path != "/mcp") status = 404;
                    else if (first[0] != "POST") status = 405;
                    else
                    {
                        await _calls.WaitAsync(_stop.Token).ConfigureAwait(false);
                        try
                        {
                            _stop.Token.ThrowIfCancellationRequested();
                            reply = await _handle(body, _stop.Token).ConfigureAwait(false);
                        }
                        finally { _calls.Release(); }
                        status = reply is null ? 202 : 200;
                    }
                    await SendAsync(stream, status, reply, _stop.Token).ConfigureAwait(false);
                    if (headers.TryGetValue("Connection", out var connection) && connection.Equals("close", StringComparison.OrdinalIgnoreCase)) return;
                }
            }
            catch (Exception ex) when (ex is OperationCanceledException or IOException or SocketException or ObjectDisposedException) { }
            catch (Exception ex) { Failed?.Invoke(ex.Message); }
            finally { _clients.TryRemove(client, out _); }
        }
    }

    private int Refusal(Dictionary<string, string> headers)
    {
        if (!headers.TryGetValue("Host", out var host) ||
            !Uri.TryCreate("http://" + host, UriKind.Absolute, out var hostUri) || !IsLoopback(hostUri)) return 403;
        if (headers.TryGetValue("Origin", out var origin) &&
            (!Uri.TryCreate(origin, UriKind.Absolute, out var uri) || !IsLoopback(uri))) return 403;
        if (!headers.TryGetValue("Authorization", out var authorization) ||
            !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(authorization), _authorization)) return 401;
        return 0;
    }

    private static bool IsLoopback(Uri uri) =>
        uri.Scheme is "http" or "https" && uri.UserInfo.Length == 0 &&
        uri.Host is "127.0.0.1" or "localhost" or "[::1]";

    private static async Task SendAsync(NetworkStream stream, int status, byte[]? body, CancellationToken token)
    {
        string extra = status == 401 ? "WWW-Authenticate: Bearer\r\n" : status == 405 ? "Allow: POST\r\n" : "";
        var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(HttpStatusCode)status}\r\nContent-Length: {body?.Length ?? 0}\r\n" +
            (body is null ? "" : "Content-Type: application/json\r\n") + extra + "\r\n");
        await stream.WriteAsync(head, token).ConfigureAwait(false);
        if (body is not null) await stream.WriteAsync(body, token).ConfigureAwait(false);
    }

    /// <summary>Immediately stops listening and cancels queued calls and incomplete requests.
    /// The session owner waits for in-flight native calls before releasing its
    /// callback delegate and retained machine context.</summary>
    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        foreach (var client in _clients.Keys) client.Dispose();
    }
}
