using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using WinRT.Interop;
using Bubilator88.Windows.GameController;
using Bubilator88.Windows.Ocr;

namespace Bubilator88.Windows;

public sealed partial class MainWindow : Window
{
    // Slices per frame on the x1 path (matches macOS's audioSlicesPerFrame).
    private const int AudioSlicesPerFrame = 4;
    // Render ticks a disk LED stays lit after an access pulse (~200 ms @ 60 Hz).
    private const int LedHoldTicks = 12;
    // Approx. non-screen chrome (menu + status + title) in DIPs, for window sizing.
    private const double ChromeHeightDip = 96.0;

    private EmulatorHost? _host;
    private D3DScreen? _screen;
    private XAudioSink? _audio;
    private FddSound? _fddSound;
    private readonly GameControllerManager _controller = new();
    private readonly OcrManager _ocr = new();
    private List<OcrDetection> _ocrDetections = new();

    // Emulation runs on its own thread (EmulationLoop); the UI thread presents
    // the frames it publishes. See RunEmulationStep / OnRendering.
    private EmulationLoop? _loop;
    private readonly FramePublisher _frames =
        new(EmulatorHost.ScreenWidth * EmulatorHost.ScreenHeight * 4);
    private FrameSlot? _lastFrame;   // newest frame the UI took; valid until the next acquire
    // Set when the last frame must be presented again without a new one from the
    // machine (resize, full screen, filter or scaling change). The emulation
    // thread publishes nothing while paused, and a resized swap chain comes back
    // blank, so OnRendering would otherwise leave the screen empty (macOS: needsRepresent).
    private bool _needsRepresent;
    private long _fpsLastPublished;

    // FDD LED / sound events, sampled per frame on the emulation thread and
    // handed to the UI thread (seek steps are counts, so the UI tick — which
    // doesn't line up with machine frames — must not sample them itself).
    private readonly object _diskEventsLock = new();
    private bool _pendingAccess0, _pendingAccess1;
    private int _pendingSeek0, _pendingSeek1;
    private bool _pendingRead0, _pendingRead1;

    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private double _lastTick;
    private int _sliceIndex;   // current x1-path slice (emulation thread only)
    private bool _paused;
    private bool _fullscreen;
    private int _windowScale = 2;   // ×1/×2/×4, persisted
    private int _emulationSpeed = 1; // fast-forward multiplier: 1/2/4/8/16
    private string _videoFilter = "None";   // None/Linear/Bicubic/CRT/xBRZ/Enhanced
    private bool _scanlineEnabled;           // scanline overlay (None/Linear/Bicubic only)

    // Settings-dialog–backed preferences (mirror the macOS Settings tabs; only
    // the ones with a working Windows backend are present). Persisted alongside
    // the menu-driven settings in settings.json.
    private string _screenshotFormat = "png";        // png/jpeg/heic
    private bool _screenshotAutoSave = true;          // matches macOS Settings.screenshotAutoSave default
    private string? _screenshotDirectory;             // null = default (~/Pictures)
    private FullscreenScaling _fullscreenScaling;     // fullscreen layout: fit / integer / 4:3 pixel aspect
    private int _audioBufferMs = 100;                 // adaptive-rate target latency (20–500)
    private string _keyboardLayout = "auto";          // auto/jis/us
    private bool _arrowKeysAsNumpad;
    private bool _numberRowAsNumpad;
    private bool _wasdAsNumpad;
    private bool _fddSoundEnabled = true;             // matches macOS Settings.fddSound default
    private int _fddSoundVolumeLevel = 2;             // 0=small 1=medium 2=large (matches macOS default)
    private string _fddSoundDeviceId = "";             // "" = System Default; matches macOS fddSoundDeviceUID
    private bool _gameControllerEnabled = true;        // matches macOS Settings.gameControllerEnabled default
    private ControllerButtonMapping _controllerMapping = ControllerButtonMapping.Defaults.Clone();

    // Boot configuration (mirrors the former combo/toggle state).
    private int _bootModeIndex;
    private bool _clock8MHz = true;
    private int _extRamCards = NativeApi.ExtRam_128KB;  // matches macOS Settings.extramCards default
    private int _monitorType = NativeApi.Monitor24kHz;  // matches macOS Settings.monitorType default
    private bool _memoryWaitDip;                        // matches macOS Settings.memoryWaitDip default (off)

    // Per-drive mounted-disk state (bytes kept so images can be switched without
    // re-reading the file; mirrors macOS MountedDiskInfo for multi-image .d88).
    private readonly DriveSlot[] _drives = { new(), new() };

    // Status-bar state.
    private int _drive0Led;
    private int _drive1Led;
    private double _fpsAccum;
    private long _aiLastPresented;   // throughput baseline for the AI-filter FPS path

    // Matches the macOS status-bar drive LED (Color.red / Color.gray in ContentView.swift).
    private readonly SolidColorBrush _ledOn = new(Microsoft.UI.Colors.Red);
    private readonly SolidColorBrush _ledOff = new(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
    // Run-state LED (mirrors the macOS status-bar dot): green = running, gray = paused.
    private readonly SolidColorBrush _runLed = new(Microsoft.UI.Colors.LimeGreen);
    private readonly SolidColorBrush _pausedLed = new(Microsoft.UI.Colors.Gray);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    private const int VkControl = 0x11;
    private static bool KeyHeld(int vk) => (GetKeyState(vk) & 0x8000) != 0;
    private static readonly RoutedEventArgs EmptyArgs = new();

    public MainWindow()
    {
        InitializeComponent();

        // Unpackaged WinUI3 apps don't pick up the exe's Win32 icon resource for
        // the titlebar/taskbar automatically (that only covers Explorer/shortcut
        // icons) — AppWindow.SetIcon must be called explicitly.
        string? iconPath = DeploymentFiles.Find(System.IO.Path.Combine("Assets", "AppIcon.ico"));
        if (iconPath is not null) AppWindow.SetIcon(iconPath);

        // Size and lock the window BEFORE App.Activate() shows it, so it doesn't
        // briefly flash at the default size before snapping to the saved scale.
        LoadSettings();
        ApplyKeyboardConfig();   // push layout + numpad-emulation prefs to KeyMapping
        ConfigureFixedSize();
        AllowOversizeWindow();
        uint dpi = GetDpiForWindow(WindowNative.GetWindowHandle(this));
        ResizeWindow(_windowScale, dpi > 0 ? dpi / 96.0 : 1.0);

        Root.Loaded += OnLoaded;
        Closed += OnClosed;
        // Park emulation while minimized, as the UI-thread loop did when
        // Rendering stopped (mirrors macOS EmulationLoop.setVisible).
        VisibilityChanged += (_, e) => _loop?.SetVisible(e.Visible);

        // Keep keyboard focus on the emulation view. Two chrome controls otherwise
        // capture it and silence OnKeyDown (the PC-8801 key matrix + Ctrl chords):
        //   • a top-level menu, which on dismissal parks focus back on its
        //     MenuBarItem  → bounced back in OnRootGettingFocus;
        //   • the volume slider, which grabs focus on a pointer press → returned
        //     when the drag/click ends.
        Root.GettingFocus += OnRootGettingFocus;
        VolumeSlider.PointerCaptureLost += (_, _) => RestoreEmulatorFocus();
    }

    /// Return keyboard focus to the emulation view so the PC-8801 key matrix and
    /// the menu chord handler (OnKeyDown) keep receiving input.
    private void RestoreEmulatorFocus() => Root.Focus(FocusState.Programmatic);

    /// When a menu closes (item chosen, Esc, click outside, or a dialog opened
    /// from it is dismissed), WinUI parks focus back on the MenuBarItem, which
    /// then reacts to keys as well as the emulator (they bubble on to Root).
    /// Catch focus arriving on a MenuBarItem from anywhere other than the
    /// emulation view or another MenuBarItem — i.e. coming back out of a menu or
    /// dialog — and, once WinUI has finished its own focus restoration, send it
    /// to the emulation view unless a menu (or any other popup) is still open.
    /// Keyboard menu access is left alone: entering the menu bar from the
    /// emulation view (old = Root) and moving along it (old = MenuBarItem) keep
    /// focus where the user put it.
    private void OnRootGettingFocus(UIElement sender, GettingFocusEventArgs e)
    {
        if (e.NewFocusedElement is not MenuBarItem) return;
        if (e.OldFocusedElement == Root || e.OldFocusedElement is MenuBarItem) return;
        DispatcherQueue.TryEnqueue(
            Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            RestoreEmulatorFocusAfterMenu);
    }

    private void RestoreEmulatorFocusAfterMenu()
    {
        if (FocusManager.GetFocusedElement(Root.XamlRoot) is MenuBarItem && !IsPopupOpen())
            RestoreEmulatorFocus();
    }

    private bool IsPopupOpen()
        => Root.XamlRoot is { } root && VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Count > 0;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _host = new EmulatorHost();
            _host.LoadRoms();
            _host.AudioBufferMs = _audioBufferMs;   // adaptive-rate target latency
            _host.SetPseudoStereo(_pseudoStereo);
            _host.SetCdMix(_cdMix);

            LoadRecent();

            // Mount a disk passed on the command line (Explorer "Open with",
            // drag-drop onto the exe, or `Bubilator88.exe game.d88`)
            // BEFORE the initial boot, so the machine boots from it. Menu mounts
            // during a session, by contrast, never reset (see MountSingleAsync).
            string? diskArg = FindDiskArgument();
            if (diskArg is not null)
                LoadDiskAtStartup(0, diskArg);

            ApplyBootConfig();   // initial boot — strap reflects drive 0 occupancy

            _screen = new D3DScreen(ScreenPanel, EmulatorHost.ScreenWidth, EmulatorHost.ScreenHeight);
            _audio = new XAudioSink();
            ApplyAudioVolume();
            VolumeSlider.Value = _volume * 100.0;

            _fddSound = new FddSound();
            _fddSound.Volume = FddSound.VolumeForLevel(_fddSoundVolumeLevel);
            if (_fddSoundEnabled) _fddSound.Start(_fddSoundDeviceId);

            _controller.Mapping = _controllerMapping;
            _controller.Enabled = _gameControllerEnabled;
            _controller.OnHostCommand = ExecuteHostCommand;

            _lastTick = _clock.Elapsed.TotalSeconds;
            CompositionTarget.Rendering += OnRendering;
            Root.Focus(FocusState.Programmatic);
            CheckForUpdateOnLaunch();

            // The window was already sized + locked in the constructor (before it
            // was shown). Here just reflect the saved scale in the View menu and
            // re-assert the size now that the XAML rasterization scale is known.
            (_windowScale switch { 1 => Scale1, 4 => Scale4, _ => Scale2 }).IsChecked = true;
            (_bootModeIndex switch { 1 => BootN88V1H, 2 => BootN88V1S, 3 => BootNBasic, _ => BootN88V2 }).IsChecked = true;
            (_clock8MHz ? Clock8 : Clock4).IsChecked = true;
            ConfigureFixedSize();
            ApplyWindowScale(_windowScale, persist: false);
            // ApplyWindowScale re-asserts the ctor's size (no SizeChanged fires),
            // so correct the panel-vs-chrome mismatch explicitly here too.
            FitWindowToContent();

            RebuildDiskMenu();
            UpdateDiskStatus();

            // Reflect the saved video filter / scanline state and push it to the
            // presenter (the screen was just created with the default filter).
            if (_videoFilter == "AIQuality" && !AIModelStore.Shared.IsInstalled(AIModelStore.Quality))
            {
                _videoFilter = "None";
                SaveSettings();
            }
            SyncVideoFilterMenu();
            ApplyVideoFilter();

            // Last, once everything the loop touches exists.
            _loop = new EmulationLoop(RunEmulationStep);
            _loop.SetFramesPerStep(_emulationSpeed);
            _loop.Start();
            _ = ApplyAutomationSettingAsync();
        }
        catch (Exception ex)
        {
            // Tear down anything that was constructed before the failure so the
            // native handle / D3D / XAudio resources don't leak. The loop goes
            // first: it must have exited before the host is destroyed.
            _loop?.Dispose();
            _loop = null;
            CompositionTarget.Rendering -= OnRendering;
            _fddSound?.Dispose();
            _audio?.Dispose();
            _screen?.Dispose();
            _host?.Dispose();
            _fddSound = null;
            _audio = null;
            _screen = null;
            _host = null;
            ShowError($"Initialization failed: {ex.Message}");
        }
    }

    /// Transient error notification (replaces the old status-bar text line,
    /// which no longer exists now the status bar mirrors macOS's layout).
    private async void ShowError(string message)
    {
        await ShowDialogAsync(new ContentDialog
        {
            Title = "Bubilator88",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = Root.XamlRoot,
        });
    }

    private bool _dialogOpen;

    /// Show a <see cref="ContentDialog"/>, serializing presentation: WinUI throws
    /// ("only a single ContentDialog can be open at any time") if a second is shown
    /// while one is up, and our callers are <c>async void</c>, so that would be an
    /// unhandled crash. A request made while one is already open is dropped, and any
    /// presentation failure (e.g. XamlRoot not ready yet) is swallowed.
    /// When the dialog closes, WinUI hands focus back to whatever opened it —
    /// usually a MenuBarItem — so focus is sent to the emulation view instead,
    /// once WinUI has finished its own restoration (unless another dialog has
    /// been opened in the meantime).
    private async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        if (_dialogOpen) return ContentDialogResult.None;
        _dialogOpen = true;
        try { return await dialog.ShowAsync(); }
        catch { return ContentDialogResult.None; }
        finally
        {
            _dialogOpen = false;
            DispatcherQueue.TryEnqueue(
                Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                () => { if (!_dialogOpen) RestoreEmulatorFocus(); });
        }
    }

    // MARK: - Boot configuration

    private (int dipSw1, int dipSw2Base) BootSelection() => _bootModeIndex switch
    {
        1 => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V1H),
        2 => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V1S),
        3 => (NativeApi.DipSw1_NBasic, NativeApi.DipSw2_V2),
        _ => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V2),
    };

    // preserveRam: false for the first boot (cold), true for user-triggered
    // re-applies (Reset / boot mode / clock), matching the macOS reset paths.
    private void ApplyBootConfig(bool preserveRam = false, bool? clockOverride = null)
    {
        if (_host is null) return;
        var (dipSw1, dipSw2Base) = BootSelection();
        _host.Configure(clockOverride ?? _clock8MHz, dipSw1, dipSw2Base, preserveRam, _extRamCards, _monitorType, _memoryWaitDip);
        ModeLabel.Text = _bootModeIndex switch
        {
            1 => "N88-V1H",
            2 => "N88-V1S",
            3 => "N-BASIC",
            _ => "N88-V2",
        };
        ClockLabel.Text = (clockOverride ?? _clock8MHz) ? "8MHz" : "4MHz";

        // New screen content makes the last OCR hash/boxes stale.
        _ocr.Reset();
    }

    // MARK: - Frame loop

    /// One tick of the emulation loop, on the emulation thread: a slice at x1,
    /// otherwise <paramref name="batch"/> whole frames (the emulation speed).
    /// Everything runs under the host lock, and <see cref="EmulationLoop.ShouldRun"/>
    /// is re-checked under it so a pause (Stop + join) is never overtaken.
    private void RunEmulationStep(int batch)
    {
        EmulatorHost host = _host!;

        if (batch == 1)
        {
            // At x1 the frame runs in slices, one per tick (mirrors macOS's
            // audio-subframe pacing, EmulatorViewModel+Rendering.swift). Audio
            // reaches XAudio2 in ~4.5ms pieces spread over the frame instead
            // of one ~18ms burst, which is what lets a short (e.g. 20ms) buffer
            // setting hold without underrunning.
            lock (host.SyncRoot)
            {
                if (!_loop!.ShouldRun) return;
                bool ended = host.RunFrameSlice(_sliceIndex, AudioSlicesPerFrame);
                if (_audio is not null) host.DrainAudio(_audio);
                if (ended)
                {
                    _sliceIndex = 0;
                    FinishFrame(host);
                }
                else
                {
                    _sliceIndex++;
                }
                // Pace from the emulated VSYNC rate (55.42Hz on a 24kHz monitor),
                // not a fixed 60Hz. It follows the CRTC programming, so it is
                // re-read after every tick.
                _loop.SetTickInterval(1.0 / (host.FrameRate * AudioSlicesPerFrame));
            }
            return;
        }

        // Emulation speed N runs N frames per tick (matches macOS
        // EmulationSpeed.framesPerDraw). Audio is drained every frame so the
        // core buffer never accumulates; the source voice plays the
        // over-produced samples back at N× (see _audio.SetFrequencyRatio).
        // The lock is released between frames so UI calls (key presses) wait
        // for at most one frame even at x16.
        for (int i = 0; i < batch; i++)
        {
            lock (host.SyncRoot)
            {
                if (!_loop!.ShouldRun) return;
                // Also finishes a frame the sliced path left part-way (switching
                // to fast forward mid-frame): RunFrame() stops at the same
                // boundary, so the next x1 tick starts at slice 0.
                host.RunFrame();
                if (_audio is not null) host.DrainAudio(_audio);
                _sliceIndex = 0;
                if (i == batch - 1)
                {
                    FinishFrame(host);
                    _loop.SetTickInterval(1.0 / host.FrameRate);
                }
            }
        }
    }

    /// The frame-end half of a tick (emulation thread, host lock held): render
    /// and publish the frame, and collect the FDD LED / sound events for the UI.
    private void FinishFrame(EmulatorHost host)
    {
        host.Render(blinkCursor: true);
        _frames.Publish(host.Pixels, host.Is400Line);

        host.SampleDiskAccess(out bool d0, out bool d1);
        host.SampleFddSoundEvents(out int seek0, out int seek1, out bool read0, out bool read1);
        lock (_diskEventsLock)
        {
            _pendingAccess0 |= d0;
            _pendingAccess1 |= d1;
            _pendingSeek0 += seek0;
            _pendingSeek1 += seek1;
            _pendingRead0 |= read0;
            _pendingRead1 |= read1;
        }
    }

    /// Render the current machine state and publish it outside the loop — for
    /// a state load while paused, where no tick would show the new screen.
    private void PublishCurrentFrame()
    {
        if (_host is null) return;
        lock (_host.SyncRoot)
        {
            _host.Render(blinkCursor: true);
            _frames.Publish(_host.Pixels, _host.Is400Line, counted: false);
        }
    }

    /// Present whatever frame the emulation thread finished last (UI thread).
    private void OnRendering(object? sender, object e)
    {
        if (_host is null || _screen is null) return;

        // Polled every tick, including while paused, so a controller-bound
        // Pause/Resume can un-pause and held buttons don't go stale.
        _controller.Poll(_host);

        // Drain any OCR result that landed since the last tick, including
        // while paused — otherwise a disable-triggered clear (Toggle(false))
        // or a pause-triggered TriggerImmediate result would sit unseen until
        // the emulator resumes.
        if (_ocr.TryTakeResult(out var ocrDetections)) UpdateOcrOverlay(ocrDetections);

        double now = _clock.Elapsed.TotalSeconds;
        double dt = now - _lastTick;
        _lastTick = now;

        if (_frames.AcquireLatest() is { } frame)
        {
            _lastFrame = frame;
            _needsRepresent = false;
            _screen.Present(frame.Pixels, frame.Is400Line);
            SampleAndDecayLeds();
            SampleFddSound();
            _ocr.Tick(dt, frame.Pixels);
        }
        else if (_needsRepresent && _lastFrame is not null)
        {
            _needsRepresent = false;
            _screen.Present(_lastFrame.Pixels, _lastFrame.Is400Line);
        }
        UpdateFps(dt);
    }

    private void SampleAndDecayLeds()
    {
        bool d0, d1;
        lock (_diskEventsLock)
        {
            d0 = _pendingAccess0;
            d1 = _pendingAccess1;
            _pendingAccess0 = _pendingAccess1 = false;
        }
        if (d0) _drive0Led = LedHoldTicks;
        if (d1) _drive1Led = LedHoldTicks;
        UpdateLed(Drive0Led, ref _drive0Led);
        UpdateLed(Drive1Led, ref _drive1Led);
    }

    /// Play the FDD seek-step / read-access sounds collected since the last
    /// presented frame (mirrors the macOS FDC callback wiring in
    /// EmulatorViewModel.init()).
    // A single presented frame can carry several seek steps (step rate can be
    // as low as ~2ms — see UPD765A.srtClocks — and the UI can skip frames the
    // loop published). Cap the replay burst at XAudio2's own hard limit
    // (XAUDIO2_MAX_QUEUED_BUFFERS = 64 per source voice) minus a small margin,
    // rather than an arbitrary lower number — this is the largest burst the
    // voice can actually hold, so it only truncates when XAudio2 itself would
    // have refused the buffer anyway.
    private const int MaxSeekClicksPerSample = 60;

    private void SampleFddSound()
    {
        int seek0, seek1;
        bool read0, read1;
        lock (_diskEventsLock)
        {
            seek0 = _pendingSeek0;
            seek1 = _pendingSeek1;
            read0 = _pendingRead0;
            read1 = _pendingRead1;
            _pendingSeek0 = _pendingSeek1 = 0;
            _pendingRead0 = _pendingRead1 = false;
        }
        if (_fddSound is not { IsEnabled: true } sound) return;
        for (int i = 0; i < Math.Min(seek0, MaxSeekClicksPerSample); i++) sound.PlaySeekStep(0);
        for (int i = 0; i < Math.Min(seek1, MaxSeekClicksPerSample); i++) sound.PlaySeekStep(1);
        if (read0) sound.PlayReadAccess(0);
        if (read1) sound.PlayReadAccess(1);
    }

    private void UpdateLed(Ellipse led, ref int counter)
    {
        Brush target = counter > 0 ? _ledOn : _ledOff;
        if (counter > 0) counter--;
        if (!ReferenceEquals(led.Fill, target)) led.Fill = target;
    }

    private void UpdateFps(double dt)
    {
        _fpsAccum += dt;
        if (_fpsAccum < 0.5) return;

        // Mirror the macOS metal view: in AI-upscale mode the meter reports inference
        // throughput (completed inferences / elapsed), which lands far below 60 Hz,
        // rather than the emulation frame count. The completed counter is monotonic
        // and frozen while the AI filter is inactive, so the delta naturally reads 0
        // on re-entry and grows from there.
        double fps;
        if (_screen is not null && _screen.TryGetAiPresentedCount(out long presented))
        {
            fps = (presented - _aiLastPresented) / _fpsAccum;
            _aiLastPresented = presented;
        }
        else
        {
            // Emulated frames, not presents: the loop publishes at the machine's
            // rate regardless of how often the display draws.
            fps = (_frames.PublishedCount - _fpsLastPublished) / _fpsAccum;
        }

        FpsLabel.Text = $"{fps:0} fps";
        _fpsAccum = 0;
        // Re-baselined on both paths, so leaving the AI filter doesn't count
        // every frame published meanwhile into the first reading.
        _fpsLastPublished = _frames.PublishedCount;
    }

    // MARK: - Emulator menu

    private void OnPauseResume(object sender, RoutedEventArgs e)
        => SetEmulatorRunning(_paused);

    private void SetEmulatorRunning(bool running)
    {
        if (_host is not { } host) return;
        if (_paused == !running) return;
        _paused = !running;
        // Stop joins by taking the host lock, so no tick is in flight once it
        // returns; Start resets the pacer so the pause isn't "caught up".
        if (_paused) _loop?.Stop(() => { lock (host.SyncRoot) { } });
        else _loop?.Start();
        PauseResumeItem.Text = _paused ? "Resume" : "Pause";
        RunStateLed.Fill = _paused ? _pausedLed : _runLed;

        // Mirrors macOS's EmulatorViewModel.stop()/start(), which tear down and
        // rebuild fddSound on every pause/resume rather than leaving it idling.
        if (_fddSound is not null)
        {
            if (_paused)
            {
                _fddSound.Stop();
            }
            else if (_fddSoundEnabled)
            {
                _fddSound.Start(_fddSoundDeviceId);
            }
        }

        // Mirrors macOS: pausing forces an immediate OCR pass (rather than
        // waiting up to ~3s) so the overlay reflects the frozen frame promptly.
        if (_paused && _ocr.Enabled && _lastFrame is not null)
            _ocr.TriggerImmediate(_lastFrame.Pixels);
    }

    private void OnReset(object sender, RoutedEventArgs e)
    {
        ResetMachine();
        // Resetting while paused would otherwise freeze the display on the
        // instant-post-reset VRAM/CRTC state — garbage the boot ROM only clears
        // once the CPU runs. Mirrors macOS reset(), which forces the restart so
        // reset always leaves the machine running. Boot mode / clock changes
        // keep the pause, as on macOS.
        if (_paused) OnPauseResume(this, EmptyArgs);
    }

    private void OnBootMode(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int idx) && idx is >= 0 and <= 3)
        {
            ResetMachine((EmulatorBootMode)idx);
        }
    }

    private void OnClock(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int mhz))
        {
            // Switching the CPU clock resets the machine, matching macOS (where
            // clock8MHz is applied through performReset, not as a live change).
            _clock8MHz = mhz == 8;
            ResetMachine();
        }
    }

    private void OnVolumeChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        _volume = Math.Clamp(e.NewValue / 100.0, 0.0, 1.0);
        ApplyAudioVolume();
        SaveSettings();
    }

    // MARK: - Disk menu

    private async void OnMountDrive0(object sender, RoutedEventArgs e) => await MountDriveAsync(0);
    private async void OnMountDrive1(object sender, RoutedEventArgs e) => await MountDriveAsync(1);

    private async Task MountDriveAsync(int drive)
    {
        if (_host is null) return;

        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".d88");
        picker.FileTypeFilter.Add(".d77");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is null) return;

        byte[] bytes = await File.ReadAllBytesAsync(file.Path);
        await MountSingleAsync(drive, file.Name, bytes, file.Path);
    }

    private static string? FindDiskArgument()
    {
        foreach (string a in Environment.GetCommandLineArgs())
        {
            string ext = System.IO.Path.GetExtension(a).ToLowerInvariant();
            if ((ext == ".d88" || ext == ".d77") && File.Exists(a))
                return a;
        }
        return null;
    }

    /// Mount a command-line disk into a slot at STARTUP (image 0, no dialog),
    /// before the initial ApplyBootConfig — so the machine boots from it. This is
    /// the one place mounting leads to a boot; the strap (set by the upcoming
    /// ApplyBootConfig) sees drive 0 occupied and selects FDD boot.
    private void LoadDiskAtStartup(int drive, string path)
    {
        if (_host is null) return;
        try
        {
            byte[] bytes = File.ReadAllBytes(path);
            string name = System.IO.Path.GetFileName(path);
            int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
            if (images <= 0) { ShowError($"Failed to parse {name}"); return; }
            MountDiskExplicit(drive, bytes, name, infos, 0, path);
        }
        catch (Exception ex) { ShowError($"Mount failed: {ex.Message}"); }
    }

    /// Mount a single drive from a .d88 blob. For a multi-image file the user is
    /// first shown an image-selection dialog (matching the macOS .multiImageD88
    /// picker sheet); single-image files mount directly. A non-null sourcePath is
    /// recorded in the recent-files list.
    private async Task MountSingleAsync(int drive, string name, byte[] bytes, string? sourcePath)
    {
        if (_host is null) return;

        int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
        if (images <= 0)
        {
            ShowError($"Failed to parse {name}");
            return;
        }

        int index = 0;
        if (images > 1)
        {
            index = await PickImageAsync(name, infos);
            if (index < 0) return;   // user cancelled
        }

        MountDiskExplicit(drive, bytes, name, infos, index, sourcePath);
        // Mounting only inserts the disk — it does NOT reset the machine (matches
        // macOS mountDiskImage). The boot strap is re-evaluated on the next Reset,
        // so the user mounts a disk and then presses Reset to boot it.

    }

    /// Show the disk-image selection dialog for a multi-image .d88 (mirrors the
    /// macOS picker: a row per image showing index, name, disk type and a lock
    /// for write-protected images; click a row to mount, or Cancel). Returns the
    /// chosen image index, or -1 if cancelled.
    private async Task<int> PickImageAsync(string fileName, EmulatorHost.ImageInfo[] images)
    {
        int chosen = -1;

        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
        };
        for (int i = 0; i < images.Length; i++)
            list.Items.Add(MakeImageRow(i, images[i]));

        var dialog = new ContentDialog
        {
            Title = "Select Disk Image",
            Content = list,
            CloseButtonText = "Cancel",
            XamlRoot = Root.XamlRoot,
        };
        list.ItemClick += (_, e) =>
        {
            chosen = list.Items.IndexOf(e.ClickedItem);
            dialog.Hide();
        };
        await ShowDialogAsync(dialog);
        return chosen;
    }

    /// One row of the image-selection dialog: "#i  Name … Type 🔒".
    private static Grid MakeImageRow(int index, EmulatorHost.ImageInfo info)
    {
        var grid = new Grid { ColumnSpacing = 12, MinWidth = 380 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });

        var idx = new TextBlock { Text = $"#{index}", Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(idx, 0);

        var name = new TextBlock
        {
            Text = info.Name,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(name, 1);

        var type = new TextBlock { Text = info.Type, Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(type, 2);

        var locked = new FontIcon
        {
            Glyph = "",   // Lock (Segoe Fluent Icons)
            FontSize = 12,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = info.WriteProtected ? Visibility.Visible : Visibility.Collapsed,
        };
        Grid.SetColumn(locked, 3);

        grid.Children.Add(idx);
        grid.Children.Add(name);
        grid.Children.Add(type);
        grid.Children.Add(locked);
        return grid;
    }

    /// Mount a (multi-image) file across both drives: image 0 → drive 1, image 1
    /// → drive 2 (matches the macOS "Drive 1&2" / 2-disk-game boot). Single-image
    /// files leave drive 2 empty.
    private void MountBothFromPath(string path)
    {
        if (_host is null) return;
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (Exception ex) { ShowError($"Mount failed: {ex.Message}"); return; }
        string name = System.IO.Path.GetFileName(path);

        int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
        if (images <= 0) { ShowError($"Failed to parse {name}"); return; }

        MountDiskExplicit(0, bytes, name, infos, 0, path);
        if (images >= 2)
        {
            MountDiskExplicit(1, bytes, name, infos, 1, path);
        }
        else
        {
            _host.EjectDisk(1);
            _drives[1] = new DriveSlot();
        }
        // Insert only — no reset (matches macOS). Press Reset to boot the set.

        AddRecent(path);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private static void FillSlot(DriveSlot slot, byte[] bytes, string name,
                                 EmulatorHost.ImageInfo[] infos, int current,
                                 string? sourcePath = null, bool writeProtected = false)
    {
        slot.Fill(bytes, name, infos, current, sourcePath, writeProtected);
    }

    /// <summary>
    /// Switch to a different image within the same mounted .d88 — a floppy swap,
    /// NOT a reboot (matches macOS switchDiskImage). The machine keeps running.
    /// </summary>
    private void SwitchImage(int drive, int index)
    {
        var slot = _drives[drive];
        if (_host is null || !slot.Occupied || index < 0 || index >= slot.ImageCount) return;
        if (index == slot.CurrentImage) return;
        // A display-only slot (source file gone after a state load) carries an
        // empty byte[] — re-mounting it would hand the core a 0-length blob and
        // wipe the disk that's actually mounted. Switching is unavailable there.
        if (slot.Bytes is not { Length: > 0 }) return;

        if (_host.MountDiskProtected(drive, slot.Bytes!, index, slot.Images[index].WriteProtected) <= 0)
        {
            ShowError("Cannot mount the disk image.");
            return;
        }
        slot.SelectImage(index);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private void OnEjectDrive0(object sender, RoutedEventArgs e) => EjectDrive(0);
    private void OnEjectDrive1(object sender, RoutedEventArgs e) => EjectDrive(1);

    private void EjectDrive(int drive)
    {
        _host?.EjectDisk(drive);
        _drives[drive] = new DriveSlot();
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private void ToggleWriteProtect(int drive)
    {
        var slot = _drives[drive];
        if (_host is null || !slot.Occupied) return;
        slot.WriteProtected = !slot.WriteProtected;
        _host.SetWriteProtect(drive, slot.WriteProtected);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    /// Resolve embedded image names, falling back to "<file> #<i>" for unnamed
    /// images (and bare "<file>" for a single-image disk). Mirrors macOS
    /// makeDirectDiskInfo.
    // MARK: - Disk menu construction (mirrors the macOS Disk menu)

    private void RebuildDiskMenu()
    {
        RebuildDriveMenu(0);
        RebuildDriveMenu(1);
        RebuildBothMenu();
        RebuildRecentMenu();
        RebuildCheatMenu();   // the active set follows the mounted disks
    }

    /// Build one drive's submenu: Mount… / Eject / Write Protect, then (when a
    /// disk is mounted) the file name and, for multi-image .d88, the image list.
    private void RebuildDriveMenu(int drive)
    {
        var sub = drive == 0 ? Drive0Sub : Drive1Sub;
        var slot = _drives[drive];
        sub.Items.Clear();

        var mount = new MenuFlyoutItem
        {
            Text = "Mount…",
            // Hint only — the chord is dispatched in OnKeyDown (see the XAML note).
            KeyboardAcceleratorTextOverride = drive == 0 ? "Ctrl+1" : "Ctrl+2",
        };
        mount.Click += drive == 0 ? OnMountDrive0 : OnMountDrive1;
        sub.Items.Add(mount);

        var eject = new MenuFlyoutItem { Text = "Eject", IsEnabled = slot.Occupied };
        eject.Click += drive == 0 ? OnEjectDrive0 : OnEjectDrive1;
        sub.Items.Add(eject);

        var wp = new ToggleMenuFlyoutItem
        {
            Text = "Write Protect",
            IsEnabled = slot.Occupied,
            IsChecked = slot.WriteProtected,
        };
        wp.Click += (_, _) => ToggleWriteProtect(drive);
        sub.Items.Add(wp);

        if (slot.Occupied)
        {
            sub.Items.Add(new MenuFlyoutSeparator());
            sub.Items.Add(new MenuFlyoutItem { Text = slot.FileName, IsEnabled = false });
            if (slot.ImageCount > 1)
            {
                for (int i = 0; i < slot.ImageCount; i++)
                {
                    int index = i;
                    var item = new RadioMenuFlyoutItem
                    {
                        Text = $"{i + 1}. {slot.ImageNames[i]}",
                        GroupName = $"Drive{drive}Images",
                        IsChecked = i == slot.CurrentImage,
                    };
                    item.Click += (_, _) => SwitchImage(drive, index);
                    sub.Items.Add(item);
                }
            }
        }
    }

    /// "Drive 1&2": mount a 2-disk set across both drives, or eject both.
    private void RebuildBothMenu()
    {
        BothSub.Items.Clear();

        var mount = new MenuFlyoutItem
        {
            Text = "Mount…",
            KeyboardAcceleratorTextOverride = "Ctrl+3",   // hint only (see OnKeyDown)
        };
        mount.Click += async (_, _) => await MountBothAsync();
        BothSub.Items.Add(mount);

        var eject = new MenuFlyoutItem
        {
            Text = "Eject",
            IsEnabled = _drives[0].Occupied || _drives[1].Occupied,
        };
        eject.Click += (_, _) => { EjectDrive(0); EjectDrive(1); };
        BothSub.Items.Add(eject);
    }

    private void RebuildRecentMenu()
    {
        RecentSub.Items.Clear();
        if (_recent.Count == 0)
        {
            RecentSub.Items.Add(new MenuFlyoutItem { Text = "No Recent Files", IsEnabled = false });
            return;
        }
        foreach (string path in _recent)
        {
            string p = path;
            var item = new MenuFlyoutItem
            {
                Text = $"{System.IO.Path.GetFileName(p)}  —  {System.IO.Path.GetDirectoryName(p)}",
            };
            item.Click += (_, _) => MountBothFromPath(p);
            RecentSub.Items.Add(item);
        }
        RecentSub.Items.Add(new MenuFlyoutSeparator());
        var clear = new MenuFlyoutItem { Text = "Clear Recent Files" };
        clear.Click += (_, _) => { _recent.Clear(); SaveRecent(); RebuildRecentMenu(); };
        RecentSub.Items.Add(clear);
    }

    private async Task MountBothAsync()
    {
        if (_host is null) return;
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".d88");
        picker.FileTypeFilter.Add(".d77");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is not null) MountBothFromPath(file.Path);
    }

    private void UpdateDiskStatus()
    {
        // The disk name is shown inside each drive's status-bar entry (like
        // macOS), not in a separate text line. Drive1Label = Drive 2 (index 1),
        // Drive0Label = Drive 1 (index 0).
        Drive1Label.Text = DriveStatusText(1);
        Drive0Label.Text = DriveStatusText(0);
        Drive1LockIcon.Visibility = _drives[1].Occupied && _drives[1].WriteProtected
            ? Visibility.Visible : Visibility.Collapsed;
        Drive0LockIcon.Visibility = _drives[0].Occupied && _drives[0].WriteProtected
            ? Visibility.Visible : Visibility.Collapsed;
    }

    /// "2: <name>" for an occupied drive, or "2: Empty". Write-protect is
    /// shown separately via Drive{0,1}LockIcon, not appended to this text.
    private string DriveStatusText(int drive)
    {
        string tag = $"{drive + 1}";
        var slot = _drives[drive];
        if (!slot.Occupied) return $"{tag}: Empty";
        string label = slot.ImageCount > 1
            ? slot.ImageNames[slot.CurrentImage]
            : slot.FileName;
        return $"{tag}: {label}";
    }

    // MARK: - Recent files (MRU persisted to %LOCALAPPDATA%\Bubilator88\recent.json)

    private const int MaxRecent = 10;
    private readonly List<string> _recent = new();

    private static string RecentPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "recent.json");

    private void LoadRecent()
    {
        try
        {
            if (!File.Exists(RecentPath)) return;
            var list = System.Text.Json.JsonSerializer.Deserialize<List<string>>(File.ReadAllText(RecentPath));
            if (list is not null)
                _recent.AddRange(list.Where(File.Exists).Take(MaxRecent));
        }
        catch { /* corrupt or unreadable — start empty */ }
    }

    private void SaveRecent()
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(RecentPath);
            if (dir is not null) Directory.CreateDirectory(dir);
            File.WriteAllText(RecentPath, System.Text.Json.JsonSerializer.Serialize(_recent));
        }
        catch { /* best effort */ }
    }

    private void AddRecent(string path)
    {
        _recent.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        _recent.Insert(0, path);
        while (_recent.Count > MaxRecent) _recent.RemoveAt(_recent.Count - 1);
        SaveRecent();
    }

    // MARK: - App settings (persisted to %LOCALAPPDATA%\Bubilator88\settings.json)

    // Persisted app settings (mirrors the macOS UserDefaults-backed Settings:
    // window scale, boot mode, CPU clock, master volume).
    private sealed class AppSettings
    {
        public bool AutomationEnabled { get; set; }
        public int AutomationPort { get; set; } = 18801;
        public string? AutomationToken { get; set; }
        public string AutomationClient { get; set; } = "claudeCode";
        public int WindowScale { get; set; } = 2;
        public int BootModeIndex { get; set; }       // 0=N88-V2 1=V1H 2=V1S 3=N-BASIC
        public bool Clock8MHz { get; set; } = true;
        public int ExtRamCards { get; set; } = NativeApi.ExtRam_128KB;  // 0=none 1=128KB 8=1MB
        public int MonitorType { get; set; } = NativeApi.Monitor24kHz;  // 0=15kHz 1=24kHz
        public bool MemoryWaitDip { get; set; }
        public double Volume { get; set; } = 0.5;    // matches macOS default
        public string VideoFilter { get; set; } = "None";  // None/Linear/Bicubic/CRT/xBRZ/Enhanced
        public bool ScanlineEnabled { get; set; }    // matches macOS default (off)
        public string ScreenshotFormat { get; set; } = "png";   // png/jpeg/heic
        public bool ScreenshotAutoSave { get; set; } = true;    // matches macOS default (on)
        public string? ScreenshotDirectory { get; set; }        // null = default (~/Pictures)
        public bool FullscreenIntegerScaling { get; set; }       // legacy; read once for migration
        public string? FullscreenScalingMode { get; set; }       // fit/integer/aspect43; null = legacy file
        public int AudioBufferMs { get; set; } = 100;            // matches macOS default
        public string KeyboardLayout { get; set; } = "auto";     // auto/jis/us
        public bool ArrowKeysAsNumpad { get; set; }
        public bool NumberRowAsNumpad { get; set; }
        public bool WasdAsNumpad { get; set; }
        public bool FddSoundEnabled { get; set; } = true;   // matches macOS Settings.fddSound default
        public int FddSoundVolumeLevel { get; set; } = 2;   // 0=small 1=medium 2=large
        public string FddSoundDeviceId { get; set; } = ""; // "" = System Default; matches macOS fddSoundDeviceUID
        public bool PseudoStereo { get; set; }   // matches macOS Settings.pseudoStereo default (off)
        public bool CdMix { get; set; }          // matches macOS Settings.cdMix default (off)
        public bool GameControllerEnabled { get; set; } = true;   // matches macOS Settings.gameControllerEnabled default
        public ControllerButtonMapping? ControllerMapping { get; set; }   // null = use defaults
        public bool AutomaticUpdateCheck { get; set; } = true;   // matches macOS Settings.automaticUpdateCheck
        public DateTime? LastUpdateCheck { get; set; }           // UTC
        public DateTime? UpdateRemindAfter { get; set; }         // UTC
        public string? SkippedUpdateVersion { get; set; }        // release tag, e.g. win-v1.2.0
    }

    private double _volume = 0.5;
    private bool _pseudoStereo;
    private bool _cdMix;

    private static string SettingsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "settings.json");

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            var s = System.Text.Json.JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath));
            if (s is null) return;
            _automationEnabled = s.AutomationEnabled;
            _automationPort = s.AutomationPort is >= 1024 and <= 65535 ? s.AutomationPort : 18801;
            if (!string.IsNullOrWhiteSpace(s.AutomationToken)) _automationToken = s.AutomationToken;
            _automationClient = s.AutomationClient;
            _windowScale = NormalizeScale(s.WindowScale);
            _bootModeIndex = Math.Clamp(s.BootModeIndex, 0, 3);
            _clock8MHz = s.Clock8MHz;
            _extRamCards = NormalizeExtRamCards(s.ExtRamCards);
            _monitorType = s.MonitorType == NativeApi.Monitor15kHz ? NativeApi.Monitor15kHz : NativeApi.Monitor24kHz;
            _memoryWaitDip = s.MemoryWaitDip;
            _volume = Math.Clamp(s.Volume, 0.0, 1.0);
            _automaticUpdateCheck = s.AutomaticUpdateCheck;
            _lastUpdateCheck = s.LastUpdateCheck;
            _updateRemindAfter = s.UpdateRemindAfter;
            _skippedUpdateVersion = s.SkippedUpdateVersion;
            _videoFilter = NormalizeFilter(s.VideoFilter);
            _scanlineEnabled = s.ScanlineEnabled;
            _screenshotFormat = NormalizeScreenshotFormat(s.ScreenshotFormat);
            _screenshotAutoSave = s.ScreenshotAutoSave;
            _screenshotDirectory = s.ScreenshotDirectory;
            _fullscreenScaling = s.FullscreenScalingMode switch
            {
                "fit" => FullscreenScaling.Fit,
                "integer" => FullscreenScaling.Integer,
                "aspect43" => FullscreenScaling.Aspect43,
                // Before the 4:3 option existed this was a bool.
                _ => s.FullscreenIntegerScaling ? FullscreenScaling.Integer : FullscreenScaling.Fit,
            };
            _audioBufferMs = Math.Clamp(s.AudioBufferMs, 20, 500);
            _keyboardLayout = NormalizeKeyboardLayout(s.KeyboardLayout);
            _arrowKeysAsNumpad = s.ArrowKeysAsNumpad;
            _numberRowAsNumpad = s.NumberRowAsNumpad;
            _wasdAsNumpad = s.WasdAsNumpad;
            _fddSoundEnabled = s.FddSoundEnabled;
            _fddSoundVolumeLevel = Math.Clamp(s.FddSoundVolumeLevel, 0, 2);
            _fddSoundDeviceId = s.FddSoundDeviceId ?? "";
            _pseudoStereo = s.PseudoStereo;
            _cdMix = s.CdMix;
            _gameControllerEnabled = s.GameControllerEnabled;
            _controllerMapping = s.ControllerMapping ?? ControllerButtonMapping.Defaults.Clone();
        }
        catch { /* corrupt or unreadable — keep defaults */ }
    }

    private void SaveSettings()
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(SettingsPath);
            if (dir is not null) Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath, System.Text.Json.JsonSerializer.Serialize(new AppSettings
            {
                AutomationEnabled = _automationEnabled,
                AutomationPort = _automationPort,
                AutomationToken = _automationToken,
                AutomationClient = _automationClient,
                WindowScale = _windowScale,
                AutomaticUpdateCheck = _automaticUpdateCheck,
                LastUpdateCheck = _lastUpdateCheck,
                UpdateRemindAfter = _updateRemindAfter,
                SkippedUpdateVersion = _skippedUpdateVersion,
                BootModeIndex = _bootModeIndex,
                Clock8MHz = _clock8MHz,
                ExtRamCards = _extRamCards,
                MonitorType = _monitorType,
                MemoryWaitDip = _memoryWaitDip,
                Volume = _volume,
                VideoFilter = _videoFilter,
                ScanlineEnabled = _scanlineEnabled,
                ScreenshotFormat = _screenshotFormat,
                ScreenshotAutoSave = _screenshotAutoSave,
                ScreenshotDirectory = _screenshotDirectory,
                FullscreenScalingMode = _fullscreenScaling switch
                {
                    FullscreenScaling.Integer => "integer",
                    FullscreenScaling.Aspect43 => "aspect43",
                    _ => "fit",
                },
                AudioBufferMs = _audioBufferMs,
                KeyboardLayout = _keyboardLayout,
                ArrowKeysAsNumpad = _arrowKeysAsNumpad,
                NumberRowAsNumpad = _numberRowAsNumpad,
                WasdAsNumpad = _wasdAsNumpad,
                FddSoundEnabled = _fddSoundEnabled,
                FddSoundVolumeLevel = _fddSoundVolumeLevel,
                FddSoundDeviceId = _fddSoundDeviceId,
                PseudoStereo = _pseudoStereo,
                CdMix = _cdMix,
                GameControllerEnabled = _gameControllerEnabled,
                ControllerMapping = _controllerMapping,
            }));
        }
        catch { /* best effort */ }
    }

    // MARK: - View menu

    private void OnWindowScale(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int scale))
            ApplyWindowScale(scale);
    }

    /// Resize the window to an exact integer view multiple and (optionally)
    /// persist it. The window cannot be freely resized (see ConfigureFixedSize),
    /// so these scales are the only way to change its size.
    // Allowed view scales are ×1/×2/×4 (matches macOS). Map any other value
    // (e.g. a ×3 left over from an older build) to the nearest allowed scale.
    private static int NormalizeScale(int s) => s <= 1 ? 1 : s == 2 ? 2 : 4;

    // Extended RAM capacity is 0 (none), 1 (128KB) or 8 (1MB) — matches
    // QUASI88's use_extram encoding. Anything else (corrupt json, future value)
    // falls back to the macOS default of 1 card (128KB).
    private static int NormalizeExtRamCards(int c) => c is NativeApi.ExtRam_None or NativeApi.ExtRam_1MB ? c : NativeApi.ExtRam_128KB;

    private void ApplyWindowScale(int scale, bool persist = true)
    {
        _windowScale = NormalizeScale(scale);
        if (persist) SaveSettings();
        if (_fullscreen) return;
        ResizeWindow(_windowScale, Root.XamlRoot?.RasterizationScale ?? 1.0);
    }

    private void ResizeWindow(int scale, double rasterScale)
    {
        int w = (int)(EmulatorHost.ScreenWidth * scale * rasterScale);
        int h = (int)((EmulatorHost.ScreenHeight * scale + ChromeHeightDip) * rasterScale);
        AppWindow.Resize(new SizeInt32(w, h));
    }

    /// Forbid arbitrary user resizing/maximizing — the window only changes size
    /// via the fixed ×1/×2/×4 view scales (matches the macOS .contentSize /
    /// disabled-resize behavior). Programmatic AppWindow.Resize still works.
    private void ConfigureFixedSize()
    {
        if (AppWindow.Presenter is OverlappedPresenter op)
        {
            op.IsResizable = false;
            op.IsMaximizable = false;
        }
    }

    private void OnToggleFullscreen(object sender, RoutedEventArgs e)
    {
        _fullscreen = !_fullscreen;
        AppWindow.SetPresenter(_fullscreen
            ? AppWindowPresenterKind.FullScreen
            : AppWindowPresenterKind.Default);
        FullscreenItem.IsChecked = _fullscreen;
        if (!_fullscreen)
        {
            // The Default presenter is freshly created — re-lock it and restore
            // the saved view scale.
            ConfigureFixedSize();
            ApplyWindowScale(_windowScale, persist: false);
        }
        // Pixel-perfect letterboxing only applies in fullscreen (windowed scales
        // are already exact integer multiples).
        ApplyIntegerScaling();
    }

    // MARK: - Video filter (mirrors the macOS VideoFilter / scanline settings)

    private static readonly string[] FilterTags =
        { "None", "Linear", "Bicubic", "CRT", "xBRZ", "Enhanced", "AIFast", "AIBalanced", "AIQuality" };

    private static string NormalizeFilter(string? s)
    {
        // Migrate the legacy single "AI" tag (which was Real-ESRGAN) to Quality.
        if (s == "AI") return "AIQuality";
        return Array.Exists(FilterTags, t => t == s) ? s! : "None";
    }

    private static string NormalizeScreenshotFormat(string? s)
        => s is "png" or "jpeg" or "heic" ? s : "png";

    private static string NormalizeKeyboardLayout(string? s)
        => s is "auto" or "jis" or "us" ? s : "auto";

    private static ScreenFilter ParseFilter(string tag) => tag switch
    {
        "Linear" => ScreenFilter.Linear,
        "Bicubic" => ScreenFilter.Bicubic,
        "CRT" => ScreenFilter.Crt,
        "xBRZ" => ScreenFilter.Xbrz,
        "Enhanced" => ScreenFilter.Enhanced,
        "AIFast" => ScreenFilter.AiFast,
        "AIBalanced" => ScreenFilter.AiBalanced,
        "AIQuality" or "AI" => ScreenFilter.AiQuality,   // "AI" = legacy Quality tag
        _ => ScreenFilter.None,
    };

    private void OnVideoFilter(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is string tag)
        {
            if (NormalizeFilter(tag) == "AIQuality" &&
                !AIModelStore.Shared.IsInstalled(AIModelStore.Quality))
            {
                SyncVideoFilterMenu();
                ShowQualityModelPanel();
                return;
            }
            _videoFilter = NormalizeFilter(tag);
            SaveSettings();
            ApplyVideoFilter();
        }
    }

    private void OnScanlines(object sender, RoutedEventArgs e)
    {
        _scanlineEnabled = ScanlineItem.IsChecked;
        SaveSettings();
        ApplyVideoFilter();
    }

    // MARK: - OCR overlay (masked: no menu entry / shortcut activates this —
    // see windows/README.md "未実装" for why. Left wired so a future revisit
    // only needs to re-add an entry point, not re-derive the pipeline.)

    private void OnToggleOcrOverlay(bool enable)
    {
        bool wasEnabled = _ocr.Enabled;
        bool ok = _ocr.Toggle(enable);
        if (!ok)
        {
            ShowToast("Japanese OCR language pack not installed");
            return;
        }

        // First activation: kick off a capture immediately rather than
        // waiting up to ~3s for the next cadence tick (matches macOS
        // toggleTranslation's first-activation triggerImmediateOCR()).
        if (_ocr.Enabled && !wasEnabled && _lastFrame is not null)
            _ocr.TriggerImmediate(_lastFrame.Pixels);
    }

    /// <summary>Replace the current OCR detection set and redraw the overlay
    /// boxes. Called from the OnRendering poll whenever a background OCR pass
    /// completes (including an empty result on disable/reset, which clears it).</summary>
    private void UpdateOcrOverlay(IReadOnlyList<OcrDetection> detections)
    {
        _ocrDetections = detections as List<OcrDetection> ?? new List<OcrDetection>(detections);
        RelayoutOcrOverlay();
    }

    /// <summary>Reposition the existing detection boxes without re-running OCR —
    /// called on window resize/fullscreen/scale changes, whose new panel size
    /// shifts the letterboxed content rect the boxes are anchored to.</summary>
    private void RelayoutOcrOverlay()
    {
        OcrOverlayCanvas.Children.Clear();
        if (_ocrDetections.Count == 0) return;

        // Must match D3DScreen.SetScaling's condition exactly
        // (non-fit layouts only apply in fullscreen) or the overlay
        // boxes and the actual rendered content diverge in windowed mode.
        var (x, y, w, h) = PixelMath.ContentRect(
            (float)ScreenPanel.ActualWidth, (float)ScreenPanel.ActualHeight,
            EmulatorHost.ScreenWidth, EmulatorHost.ScreenHeight, _fullscreen ? _fullscreenScaling : FullscreenScaling.Fit);
        if (w <= 0 || h <= 0) return;

        foreach (OcrDetection d in _ocrDetections)
        {
            Rect r = d.NormalizedRect;
            var border = new Border
            {
                CornerRadius = new CornerRadius(4),
                BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray) { Opacity = 0.5 },
                BorderThickness = new Thickness(1),
                Width = Math.Max(0, r.Width * w),
                Height = Math.Max(0, r.Height * h),
            };
            Canvas.SetLeft(border, x + r.X * w);
            Canvas.SetTop(border, y + r.Y * h);
            OcrOverlayCanvas.Children.Add(border);
        }
    }

    /// Push the current filter + scanline state to the D3D presenter and reflect
    /// the scanline availability in the UI (scanlines apply to None/Linear/Bicubic
    /// only, matching macOS isScanlineAvailable).
    private void ApplyVideoFilter()
    {
        var filter = ParseFilter(_videoFilter);
        _screen?.SetFilter(filter, _scanlineEnabled);
        _needsRepresent = true;
        ScanlineItem.IsEnabled = D3DScreen.FilterSupportsScanlines(filter);
    }

    private void SyncVideoFilterMenu()
    {
        (_videoFilter switch
        {
            "Linear" => FilterLinear,
            "Bicubic" => FilterBicubic,
            "CRT" => FilterCRT,
            "xBRZ" => FilterXBRZ,
            "Enhanced" => FilterEnhanced,
            "AIFast" => FilterAIFast,
            "AIBalanced" => FilterAIBalanced,
            "AIQuality" or "AI" => FilterAIQuality,
            _ => FilterNone,
        }).IsChecked = true;
        ScanlineItem.IsChecked = _scanlineEnabled;
    }

    // MARK: - Help menu
    // OnAbout lives in MainWindow.AboutDialog.cs (mirrors the Settings dialog split).

    // MARK: - Control menu (emulation speed, screenshot, save states)

    /// Emulation fast-forward. Speed N runs N emulation frames per draw and plays the
    /// over-produced audio back at N× (matches macOS EmulationSpeed / varispeed).
    /// From <see cref="MutedEmulationSpeed"/> up the audio is muted instead: at
    /// 3–4 octaves up the music is just noise.
    private void OnEmulationSpeed(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int n))
        {
            _emulationSpeed = Math.Clamp(n, 1, 16);
            _loop?.SetFramesPerStep(_emulationSpeed);
            _audio?.SetFrequencyRatio(_emulationSpeed);
            ApplyAudioVolume();
        }
    }

    private const int MutedEmulationSpeed = 8;

    /// The volume slider's level, or silence while fast-forwarding at
    /// <see cref="MutedEmulationSpeed"/> or above. Samples are still submitted
    /// either way, so the queue — and the core's rate control — carries on as
    /// usual and returning to a lower speed doesn't start from an empty buffer.
    private void ApplyAudioVolume()
        => _audio?.SetVolume(_emulationSpeed >= MutedEmulationSpeed ? 0f : (float)_volume);

    /// Capture the current frame through the active video filter (CRT phosphor,
    /// xBRZ, scanlines, …) for screenshots/thumbnails, mirroring the macOS
    /// filter-included capture. Falls back to the raw 640×400 buffer if the
    /// presenter can't read back. Must be called on the UI thread.
    private (byte[] pixels, int w, int h) CaptureFrame()
    {
        if (_screen is not null)
        {
            byte[]? filtered = _screen.CaptureFiltered(out int w, out int h);
            if (filtered is not null) return (filtered, w, h);
        }
        byte[] raw = _lastFrame?.Pixels.ToArray()
                     ?? new byte[EmulatorHost.ScreenWidth * EmulatorHost.ScreenHeight * 4];
        return (raw, EmulatorHost.ScreenWidth, EmulatorHost.ScreenHeight);
    }

    private async void OnSaveScreenshot(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;
        var (pixels, cw, ch) = CaptureFrame();   // snapshot (filtered) before awaits

        // Honor the screenshot format chosen in Settings (PNG/JPEG/HEIC), matching
        // the macOS Settings screenshot-format picker.
        var (_, ext, label) = ImageCodec.FormatInfo(_screenshotFormat);
        string defaultName = $"Bubilator88-{DateTime.Now:yyyyMMdd-HHmmss}";

        // Auto-save mode writes straight to the configured directory (default
        // ~/Pictures) with no prompt; ask-every-time mode shows a save picker.
        // Mirrors macOS EmulatorViewModel.saveScreenshot's screenshotAutoSave branch.
        string path;
        if (_screenshotAutoSave)
        {
            string dir = _screenshotDirectory
                ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
            Directory.CreateDirectory(dir);
            path = System.IO.Path.Combine(dir, defaultName + ext);
        }
        else
        {
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
            picker.FileTypeChoices.Add(label, new List<string> { ext });
            picker.SuggestedFileName = defaultName;
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

            StorageFile? file = await picker.PickSaveFileAsync();
            if (file is null) return;
            path = file.Path;
        }

        try
        {
            byte[] data = await ImageCodec.EncodeAsync(pixels, cw, ch, _screenshotFormat);
            await File.WriteAllBytesAsync(path, data);
            // macOS only toasts in auto-save mode — the picker itself confirms the
            // save when the user chose the location by hand.
            if (_screenshotAutoSave) ShowToast("Screenshot saved");
        }
        catch (Exception ex) { ShowError($"Screenshot failed: {ex.Message}"); }
    }

    private async void OnCopyScreen(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;
        var (pixels, cw, ch) = CaptureFrame();
        try
        {
            byte[] png = await ImageCodec.EncodePngAsync(pixels, cw, ch);
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);
            var data = new DataPackage();
            data.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
            Clipboard.SetContent(data);
            ShowToast("Screen copied");
        }
        catch (Exception ex) { ShowError($"Copy failed: {ex.Message}"); }
    }

    private async void OnQuickSave(object sender, RoutedEventArgs e) => await SaveToSlotAsync(-1);
    private async void OnQuickLoad(object sender, RoutedEventArgs e) => await LoadFromSlotAsync(-1);
    private async void OnSaveStateSheet(object sender, RoutedEventArgs e) => await ShowSlotDialogAsync(save: true);
    private async void OnLoadStateSheet(object sender, RoutedEventArgs e) => await ShowSlotDialogAsync(save: false);

    // slot < 0 = quick save/load; 0..9 = numbered slots.
    private Task SaveToSlotAsync(int slot)
    {
        if (_host is null) return Task.CompletedTask;
        try
        {
            Directory.CreateDirectory(WinSaveState.Dir);
            SaveStateFile(WinSaveState.StatePath(slot));
            ShowToast(slot < 0 ? "Quick saved" : $"Saved to slot {slot + 1}");
        }
        catch (Exception ex) { ShowError($"Save failed: {ex.Message}"); }
        return Task.CompletedTask;
    }

    private Task LoadFromSlotAsync(int slot)
    {
        if (_host is null) return Task.CompletedTask;
        if (!WinSaveState.Exists(slot)) { ShowToast("Save state not found"); return Task.CompletedTask; }
        try
        {
            LoadStateFile(WinSaveState.StatePath(slot));
            ShowToast(slot < 0 ? "Quick loaded" : $"Loaded slot {slot + 1}");
        }
        catch (Exception ex) { ShowError($"Load failed: {ex.Message}"); }
        return Task.CompletedTask;
    }
    private WinSaveMeta BuildMeta() => new()
    {
        BootModeIndex = _bootModeIndex,
        Clock8MHz = _clock8MHz,
        MonitorType = _host?.MonitorType ?? _monitorType,
        MemoryWaitDip = _host?.MemoryWaitDip ?? _memoryWaitDip,
        Drive0 = MetaForDrive(0),
        Drive1 = MetaForDrive(1),
    };

    private WinSaveMeta.DriveMeta? MetaForDrive(int drive)
    {
        var slot = _drives[drive];
        if (!slot.Occupied) return null;
        return new WinSaveMeta.DriveMeta
        {
            FileName = slot.FileName,
            ImageNames = slot.ImageNames,
            ImageCount = slot.ImageCount,
            CurrentImage = slot.CurrentImage,
            WriteProtected = slot.WriteProtected,
            SourcePath = slot.SourcePath,
        };
    }

    /// Re-sync host UI state (boot mode, clock, disk menu/labels) after a load.
    /// Does NOT reset the machine — the state is already restored in the core.
    private void ApplyLoadedMeta(WinSaveMeta? meta, bool persist = true)
    {
        if (meta is not null)
        {
            if (meta.BootModeIndex is >= 0 and <= 3) _bootModeIndex = meta.BootModeIndex;
            _clock8MHz = meta.Clock8MHz;
        }
        else
        {
            _clock8MHz = _host?.Clock8MHz ?? _clock8MHz;
        }

        // Outside the null check on purpose, like macOS performLoad: the
        // restored CRTC geometry belongs to one monitor, and a state without
        // metadata (or without the field) predates it and was 24kHz. Mirror it
        // into the setting so the next Reset does not change the frame rate back.
        _monitorType = meta?.MonitorType == NativeApi.Monitor15kHz ? NativeApi.Monitor15kHz : NativeApi.Monitor24kHz;
        if (_host is not null) _host.MonitorType = _monitorType;

        // The state brings its own extended RAM, or none; match the setting so
        // the next Reset does not install a different size.
        if (_host is not null) _extRamCards = NormalizeExtRamCards(_host.ExtRamCards);

        // Memory wait only changes the speed; older states omit it and keep
        // the current setting.
        if (meta?.MemoryWaitDip is bool memoryWait)
        {
            _memoryWaitDip = memoryWait;
            if (_host is not null) _host.MemoryWaitDip = memoryWait;
        }

        (_bootModeIndex switch { 1 => BootN88V1H, 2 => BootN88V1S, 3 => BootNBasic, _ => BootN88V2 }).IsChecked = true;
        (_clock8MHz ? Clock8 : Clock4).IsChecked = true;
        ModeLabel.Text = _bootModeIndex switch { 1 => "N88-V1H", 2 => "N88-V1S", 3 => "N-BASIC", _ => "N88-V2" };
        ClockLabel.Text = _clock8MHz ? "8MHz" : "4MHz";
        if (persist) SaveSettings();

        // Keep the core's DIP switches consistent with the restored boot mode so a
        // later Reset behaves as the saved mode (the state omits DIP switches).
        if (_host is not null)
        {
            var (dipSw1, dipSw2Base) = BootSelection();
            _host.SyncDip(dipSw1, dipSw2Base);
        }

        _drives[0] = ReconstructDrive(0, meta?.Drive0);
        _drives[1] = ReconstructDrive(1, meta?.Drive1);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    /// Rebuild a drive's host-side tracking after a load. The disk itself is
    /// already mounted in the core (restored from the .b88s), so we never remount
    /// the current image (that would discard in-state disk writes); we only
    /// reconstruct the UI/menu model. If the original file is still on disk we
    /// re-read it so multi-image switching keeps working; otherwise we synthesize
    /// a display-only slot from the metadata.
    private DriveSlot ReconstructDrive(int drive, WinSaveMeta.DriveMeta? dm)
    {
        var slot = new DriveSlot();
        if (dm is null) return slot;

        if (dm.SourcePath is not null && File.Exists(dm.SourcePath) && _host is not null)
        {
            try
            {
                byte[] bytes = File.ReadAllBytes(dm.SourcePath);
                int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
                if (images > 0)
                {
                    int idx = Math.Clamp(dm.CurrentImage, 0, images - 1);
                    FillSlot(slot, bytes, System.IO.Path.GetFileName(dm.SourcePath), infos, idx, dm.SourcePath);
                    slot.WriteProtected = dm.WriteProtected;   // honor any runtime WP toggle
                    return slot;
                }
            }
            catch { /* fall through to the display-only reconstruction */ }
        }

        // No usable source file — display-only slot (image switching unavailable).
        slot.Bytes = Array.Empty<byte>();
        slot.FileName = dm.FileName;
        slot.ImageCount = Math.Max(1, dm.ImageCount);
        slot.ImageNames = dm.ImageNames.Length > 0 ? dm.ImageNames : new[] { dm.FileName };
        slot.CurrentImage = Math.Clamp(dm.CurrentImage, 0, slot.ImageCount - 1);
        slot.WriteProtected = dm.WriteProtected;
        slot.SourcePath = dm.SourcePath;
        return slot;
    }

    /// Save/Load slot picker — a 10-slot grid with thumbnails, mirroring the
    /// macOS SaveStateSheetView. Click a slot to act; in load mode empty slots
    /// are dimmed and non-interactive.
    private async Task ShowSlotDialogAsync(bool save)
    {
        var gv = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            MaxHeight = 460,
        };
        for (int i = 0; i < WinSaveState.SlotCount; i++)
            gv.Items.Add(MakeSlotCell(i, save));

        var dialog = new ContentDialog
        {
            Title = save ? "Save State" : "Load State",
            Content = gv,
            CloseButtonText = "Cancel",
            XamlRoot = Root.XamlRoot,
        };
        gv.ItemClick += async (_, ev) =>
        {
            if (ev.ClickedItem is FrameworkElement fe && fe.Tag is int slot)
            {
                dialog.Hide();
                if (save) await SaveToSlotAsync(slot);
                else await LoadFromSlotAsync(slot);
            }
        };
        await ShowDialogAsync(dialog);
    }

    private FrameworkElement MakeSlotCell(int slot, bool save)
    {
        bool exists = WinSaveState.Exists(slot);
        var preview = exists ? WinSaveState.ReadPreview(slot) : default;
        var grid = new Grid { Width = 232, Height = 150 };

        if (preview.Thumbnail is { } thumbnail)
        {
            var image = new Image { Stretch = Stretch.UniformToFill };
            image.Loaded += async (_, _) =>
            {
                try
                {
                    using var stream = new InMemoryRandomAccessStream();
                    await stream.WriteAsync(thumbnail.AsBuffer());
                    stream.Seek(0);
                    var bitmap = new BitmapImage();
                    await bitmap.SetSourceAsync(stream);
                    image.Source = bitmap;
                }
                catch { /* A missing preview must not prevent loading a state. */ }
            };
            grid.Children.Add(image);
        }
        else
        {
            grid.Background = new SolidColorBrush(Color.FromArgb(0xB3, 0, 0, 0));
            grid.Children.Add(new TextBlock
            {
                Text = "Empty",
                Opacity = 0.4,
                FontSize = 18,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        WinSaveMeta? meta = preview.Metadata;
        string label = $"Slot {slot + 1}";
        if (exists)
        {
            string date = WinSaveState.ModifiedAt(slot)?.ToString("MM/dd HH:mm") ?? "";
            string disks = SlotDiskNames(meta);
            if (date.Length > 0) label += "  " + date;
            if (disks.Length > 0) label += "  " + disks;
        }
        grid.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Bottom,
            Padding = new Thickness(8, 4, 8, 4),
            Child = new TextBlock
            {
                Text = label,
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            },
        });

        var border = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Child = grid,
            Tag = slot,
        };
        if (!save && !exists)
        {
            border.Opacity = 0.4;
            border.IsHitTestVisible = false;   // can't load an empty slot
        }
        return border;
    }

    private static string SlotDiskNames(WinSaveMeta? meta)
    {
        if (meta is null) return "";
        var names = new List<string>();
        string? n0 = meta.Drive0?.FileName;
        string? n1 = meta.Drive1?.FileName;
        if (!string.IsNullOrEmpty(n0)) names.Add(n0!);
        if (!string.IsNullOrEmpty(n1) && n1 != n0) names.Add(n1!);
        return string.Join(", ", names);
    }

    /// Brief non-modal notification (mirrors the macOS showToast), auto-removed
    /// after ~1.2 s. Sits over the screen panel, bottom-center.
    private async void ShowToast(string message)
    {
        try
        {
            var toast = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xCC, 0, 0, 0)),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(16, 8, 16, 8),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 0, 24),
                IsHitTestVisible = false,
                Child = new TextBlock
                {
                    Text = message,
                    FontSize = 13,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                },
            };
            Grid.SetRow(toast, 1);
            Root.Children.Add(toast);
            await Task.Delay(1200);
            Root.Children.Remove(toast);
        }
        catch { /* best-effort UI */ }
    }

    // MARK: - Input & lifetime

    private void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Fit FIRST, and unconditionally — the first valid layout happens before
        // _screen exists, and OnLoaded re-asserts the same size (no SizeChanged),
        // so gating the fit on _screen would skip the only chance to correct the
        // initial size.
        FitWindowToContent();
        RelayoutOcrOverlay();
        if (_screen is null) return;
        int w = (int)(ScreenPanel.ActualWidth * ScreenPanel.CompositionScaleX);
        int h = (int)(ScreenPanel.ActualHeight * ScreenPanel.CompositionScaleY);
        _screen.Resize(w, h);
        _needsRepresent = true;
    }

    private bool _fitting;

    /// Correct the window size so the screen panel is *exactly* 640×400×scale,
    /// eliminating the letterbox padding that appears when the actual chrome
    /// (title bar + menu + status bar) differs from the ChromeHeightDip estimate
    /// used by ResizeWindow. Chrome size is constant, so this converges in one
    /// correction: after the resize the panel matches the target and the next
    /// pass is a no-op.
    private void FitWindowToContent()
    {
        if (_fullscreen || _fitting) return;
        double sx = ScreenPanel.CompositionScaleX <= 0 ? 1.0 : ScreenPanel.CompositionScaleX;
        double sy = ScreenPanel.CompositionScaleY <= 0 ? 1.0 : ScreenPanel.CompositionScaleY;

        int panelW = (int)Math.Round(ScreenPanel.ActualWidth * sx);
        int panelH = (int)Math.Round(ScreenPanel.ActualHeight * sy);
        if (panelW <= 0 || panelH <= 0) return;

        int targetW = (int)Math.Round(EmulatorHost.ScreenWidth * _windowScale * sx);
        int targetH = (int)Math.Round(EmulatorHost.ScreenHeight * _windowScale * sy);

        // chrome (physical px) = current window outer size − current panel size.
        var size = AppWindow.Size;
        int desiredW = targetW + (size.Width - panelW);
        int desiredH = targetH + (size.Height - panelH);
        if (Math.Abs(desiredW - size.Width) <= 1 && Math.Abs(desiredH - size.Height) <= 1) return;

        _fitting = true;
        try { AppWindow.Resize(new SizeInt32(desiredW, desiredH)); }
        finally { _fitting = false; }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Root's KeyDown also sees keys bubbling up from focused chrome (a
        // MenuBarItem during keyboard menu navigation). Those belong to that
        // control, so only act when the emulation view itself has focus.
        if (!ReferenceEquals(e.OriginalSource, Root)) return;

        // Host menu shortcuts win over emulator key input. The screen greedily
        // consumes letter/number keys (they map to the PC-8801 matrix), which
        // pre-empts the menu's accelerators, so the chords are dispatched here;
        // the menu shows them via KeyboardAcceleratorTextOverride (hint only, no
        // double-fire). Modifier state is read from the live keyboard.
        if (TryHandleMenuShortcut(e.Key)) { e.Handled = true; return; }

        // Only swallow keys the emulator actually consumes, so system
        // accelerators (Alt+F4 etc.) and unmapped keys keep working.
        if (_host?.KeyDown(e.Key) == true)
            e.Handled = true;
    }

    /// Dispatch the menu keyboard shortcuts (the chords shown as hints on the menu
    /// items). Returns true when the key was a shortcut and was handled.
    private bool TryHandleMenuShortcut(VirtualKey key)
    {
        if (key == VirtualKey.F11) { OnToggleFullscreen(this, EmptyArgs); return true; }

        if (!KeyHeld(VkControl)) return false;

        switch (key)
        {
            case VirtualKey.R: OnReset(this, EmptyArgs); return true;
            case VirtualKey.P: OnPauseResume(this, EmptyArgs); return true;
            case VirtualKey.S: OnQuickSave(this, EmptyArgs); return true;
            case VirtualKey.L: OnQuickLoad(this, EmptyArgs); return true;
            case VirtualKey.Number1: _ = MountDriveAsync(0); return true;
            case VirtualKey.Number2: _ = MountDriveAsync(1); return true;
            case VirtualKey.Number3: _ = MountBothAsync(); return true;
            default: return false;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        // Releases are always passed on, so a key pressed in the emulation view
        // and let go after focus moved (e.g. into the menu) doesn't stick; but a
        // key bubbling up from other chrome is left unhandled for that control.
        if (_host?.KeyUp(e.Key) == true && ReferenceEquals(e.OriginalSource, Root))
            e.Handled = true;
    }

    private void OnClosed(object sender, WindowEventArgs e)
    {
        _automationClosing = true;
        _automationServer?.Dispose();
        _automationServer = null;
        if (_automationSession is { } session)
        {
            session.Cancel();
            _ = session.DisposeAsync();
            _automationSession = null;
        }
        _aiDownloadCancellation?.Cancel();
        _aiDownloadPanel = null;
        CompositionTarget.Rendering -= OnRendering;
        // Stop the emulation thread before anything it touches is disposed.
        _loop?.Dispose();
        _loop = null;
        if (_host is not null) _controller.ReleaseAll(_host);
        _ocr.Dispose();
        _fddSound?.Dispose();
        _audio?.Dispose();
        _screen?.Dispose();
        _host?.Dispose();
    }

    /// <summary>Dispatch a controller-bound host command to the corresponding
    /// existing menu-command handler (fire-and-forget for the async ones).</summary>
    private void ExecuteHostCommand(HostCommand command)
    {
        switch (command)
        {
            case HostCommand.PauseResume: OnPauseResume(this, EmptyArgs); break;
            case HostCommand.Reset: OnReset(this, EmptyArgs); break;
            case HostCommand.QuickSave: OnQuickSave(this, EmptyArgs); break;
            case HostCommand.QuickLoad: OnQuickLoad(this, EmptyArgs); break;
            case HostCommand.ToggleFullscreen: OnToggleFullscreen(this, EmptyArgs); break;
            case HostCommand.Screenshot: OnSaveScreenshot(this, EmptyArgs); break;
            case HostCommand.CopyScreen: OnCopyScreen(this, EmptyArgs); break;
        }
    }
}
