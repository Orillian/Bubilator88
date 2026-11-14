using System;
using System.Threading;

namespace Bubilator88.Windows;

internal enum EmulatorBootMode { N88V2 = 0, N88V1H = 1, N88V1S = 2, NBasic = 3 }

/// <summary>Application operations shared by menus and automation. Each method
/// is called on the UI thread; methods own their normal machine transactions.</summary>
internal interface IEmulatorAppCommands
{
    bool IsRunning { get; }
    void SetRunning(bool running);
    void PublishFrame();
    void Reset(EmulatorBootMode? mode, bool? clock8MHz);
    string MountDisk(int drive, string path, int imageIndex, bool writeProtected);
    void EjectDisk(int drive);
    void SaveState(string path);
    void LoadState(string path);
}

/// <summary>Windows counterpart of AppAutomationHost. Routes machine operations
/// to their serial executor and application operations to the UI. Knows no MCP
/// tool names, JSON messages, operation numbers or native callback pointers.</summary>
internal sealed class AppAutomationHost
{
    private readonly IEmulatorAppCommands _commands;
    private readonly Action<Action> _withMachine;
    private readonly Func<Func<bool>, CancellationToken, bool> _runFrame;
    private readonly AutomationUiDispatcher _ui;

    public AppAutomationHost(IEmulatorAppCommands commands, Action<Action> withMachine,
        Func<Func<bool>, CancellationToken, bool> runFrame, AutomationUiDispatcher ui)
    {
        _commands = commands; _withMachine = withMachine; _runFrame = runFrame; _ui = ui;
    }

    public void WithMachine(Action action) => _withMachine(action);
    public bool RunFrame(Func<bool> beforeEach, CancellationToken token) => _runFrame(beforeEach, token);
    public void PublishFrame(CancellationToken token) => _ui.Invoke(_commands.PublishFrame, token);
    public bool IsRunning(CancellationToken token) => _ui.Invoke(() => _commands.IsRunning, token);
    public void SetRunning(bool running, CancellationToken token) => _ui.Invoke(() => _commands.SetRunning(running), token);
    public void SetDebuggerAttached(bool attached, Action action, CancellationToken token) =>
        _ui.Invoke(() => _withMachine(action), token);
    public void Reset(bool cold, EmulatorBootMode? mode, bool? clock8MHz, CancellationToken token) =>
        _ui.Invoke(() => _commands.Reset(mode, clock8MHz), token);
    public string MountDisk(int drive, string path, int imageIndex, bool writeProtected, CancellationToken token) =>
        _ui.Invoke(() => _commands.MountDisk(drive, path, imageIndex, writeProtected), token);
    public void EjectDisk(int drive, CancellationToken token) => _ui.Invoke(() => _commands.EjectDisk(drive), token);
    public void SaveState(string path, CancellationToken token) => _ui.Invoke(() => _commands.SaveState(path), token);
    public void LoadState(string path, CancellationToken token) => _ui.Invoke(() => _commands.LoadState(path), token);
}
