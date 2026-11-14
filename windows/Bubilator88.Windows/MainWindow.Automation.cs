using System;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private bool _automationEnabled;
    private int _automationPort = 18801;
    private string _automationToken = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    private string _automationClient = "claudeCode";
    private AutomationHTTPServer? _automationServer;
    private AutomationSession? _automationSession;
    private readonly SemaphoreSlim _automationLifecycle = new(1);
    private bool _automationClosing;
    private string AutomationUrl => $"http://127.0.0.1:{_automationPort}/mcp";

    private async Task ApplyAutomationSettingAsync()
    {
        // Cancellation never waits for the UI: callbacks already waiting for
        // it wake up, and session destruction follows the last native request.
        _automationServer?.Dispose();
        _automationSession?.Cancel();
        await _automationLifecycle.WaitAsync();
        try
        {
            _automationServer?.Dispose();
            _automationServer = null;
            if (_automationSession is { } previous)
            {
                await previous.DisposeAsync();
                _automationSession = null;
            }
            if (!_automationEnabled || _host is not { } host || _automationClosing) return;
            string version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";
            var ui = new AutomationUiDispatcher(action => !_automationClosing && DispatcherQueue.TryEnqueue(() => action()));
            var appHost = new AppAutomationHost(this,
                action => host.InvokeMachineAction(() => { action(); return 0; }),
                (beforeEach, token) => host.InvokeMachineAction(() =>
                {
                    token.ThrowIfCancellationRequested();
                    if (_loop is null || _loop.ShouldRun || !beforeEach()) return 0;
                    host.RunFrame();
                    host.DiscardAudio();
                    _sliceIndex = 0;
                    return 1;
                }) == 1, ui);
            var session = new AutomationSession(host.CreateAppMcpSession, version, appHost);
            _automationSession = session;
            var server = new AutomationHTTPServer(_automationPort, _automationToken, session.HandleAsync);
            server.Failed += message => DispatcherQueue.TryEnqueue(() =>
            {
                if (ReferenceEquals(_automationServer, server)) ShowError($"AI Control Unavailable: {message}");
            });
            _automationServer = server;
            server.Start();
        }
        catch (Exception ex)
        {
            _automationServer?.Dispose();
            _automationServer = null;
            if (_automationSession is { } failed)
            {
                await failed.DisposeAsync();
                _automationSession = null;
            }
            if (!_automationClosing) ShowError($"AI Control Unavailable: {ex.Message}");
        }
        finally { _automationLifecycle.Release(); }
    }

    private FrameworkElement BuildAutomationSettings()
    {
        var endpoint = new TextBox { Text = AutomationUrl, IsReadOnly = true };
        var registration = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100 };
        var client = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var instruction = Caption("");
        foreach (var entry in AutomationRegistration.Clients)
        {
            var item = new ComboBoxItem { Content = entry.Name, Tag = entry };
            client.Items.Add(item);
            if (entry.Id == _automationClient) client.SelectedItem = item;
        }
        if (client.SelectedItem is null) client.SelectedIndex = 0;
        void Refresh()
        {
            endpoint.Text = AutomationUrl;
            if (client.SelectedItem is not ComboBoxItem { Tag: AutomationRegistration.Client selected }) return;
            registration.Text = AutomationRegistration.Create(selected.Id, AutomationUrl, _automationToken);
            instruction.Text = selected.Instruction;
        }
        client.SelectionChanged += (_, _) =>
        {
            if (client.SelectedItem is not ComboBoxItem { Tag: AutomationRegistration.Client selected }) return;
            _automationClient = selected.Id;
            SaveSettings(); Refresh();
        };
        var port = new NumberBox { Header = "Port", Minimum = 1024, Maximum = 65535, Value = _automationPort, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        port.ValueChanged += (sender, e) =>
        {
            if (double.IsNaN(e.NewValue) || e.NewValue < 1024 || e.NewValue > 65535 || e.NewValue != Math.Truncate(e.NewValue)) return;
            _automationPort = (int)e.NewValue;
            SaveSettings(); _ = ApplyAutomationSettingAsync(); Refresh();
        };
        var enable = Toggle("Allow control from AI tools", _automationEnabled, on =>
        {
            _automationEnabled = on;
            SaveSettings(); _ = ApplyAutomationSettingAsync();
        });
        var copy = new Button { Content = "Copy registration" };
        copy.Click += (_, _) =>
        {
            var data = new DataPackage(); data.SetText(registration.Text); Clipboard.SetContent(data);
        };
        Refresh();
        return Section("AI Control (MCP)", new FrameworkElement[] { enable, port, endpoint, client, registration, instruction, copy },
            "Connect AI tools to this emulator over localhost. The registration includes a private access token. " +
            "Tool execution and debugger state are shared with this window.");
    }
}
