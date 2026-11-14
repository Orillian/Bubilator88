using System;
using System.Collections.Generic;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;
using Bubilator88.Windows.GameController;

namespace Bubilator88.Windows;

/// <summary>
/// The Settings dialog — a faithful (form-level) port of the macOS Settings
/// window (Bubilator88/Views/SettingsView.swift). macOS opens it from the
/// application-menu Preferences item; Windows has no such menu, so it opens from
/// the Emulator menu instead.
///
/// <para>The macOS window has five tabs (General / Display / Audio / Keyboard /
/// Controller). Most of those settings drive features the Windows native
/// host doesn't implement yet (mouse, immersive audio, translation, recording,
/// …), so this dialog mirrors the tab layout but surfaces only the preferences
/// that have a working Windows backend — Controller included, backed by
/// Windows.Gaming.Input.Gamepad (see GameController/GameControllerManager.cs).
/// Each control applies live and persists to settings.json immediately,
/// matching the macOS bindings (there is no OK/Cancel — just Close).</para>
/// </summary>
public sealed partial class MainWindow
{
    /// <summary>Push the keyboard layout + numpad-emulation prefs into the static
    /// <see cref="KeyMapping"/> resolver. Called at startup and on every change.</summary>
    private void ApplyKeyboardConfig()
    {
        KeyMapping.Layout = _keyboardLayout switch
        {
            "jis" => KeyMapping.KbLayout.Jis,
            "us" => KeyMapping.KbLayout.Us,
            _ => KeyMapping.KbLayout.Auto,
        };
        KeyMapping.ArrowKeysAsNumpad = _arrowKeysAsNumpad;
        KeyMapping.NumberRowAsNumpad = _numberRowAsNumpad;
        KeyMapping.WasdAsNumpad = _wasdAsNumpad;
    }

    /// <summary>Integer and 4:3 layouts apply only in fullscreen (the windowed
    /// view scales are already exact integer multiples of 640×400).</summary>
    private void ApplyIntegerScaling()
    {
        _screen?.SetScaling(_fullscreen ? _fullscreenScaling : FullscreenScaling.Fit);
        _needsRepresent = true;
        RelayoutOcrOverlay(); // letterbox rect changed — reposition existing OCR boxes
    }

    private async void OnSettings(object sender, RoutedEventArgs e)
    {
        // SelectorBar (Windows App SDK 1.5+) is the successor to Pivot for a
        // handful of views: it only draws the headers, so the selected tab's
        // content is swapped into the presenter below. Every tab is built up
        // front, as with Pivot, so switching keeps each tab's control state.
        var tabs = new (string Header, FrameworkElement Content)[]
        {
            ("General", WrapTab(BuildGeneralTab())),
            ("Display", WrapTab(BuildDisplayTab())),
            ("Audio", WrapTab(BuildAudioTab())),
            ("Keyboard", WrapTab(BuildKeyboardTab())),
            ("Controller", WrapTab(BuildControllerTab())),
        };

        var bar = new SelectorBar();
        // Fixed height: the dialog is centred on its content, so letting each
        // tab size it would move the tab bar on every switch. Short tabs
        // top-align; tall ones scroll. A ContentDialog never grows past the
        // window, so in a small window the height shrinks to fit (title, tab
        // bar and Close button take the ~230px) — otherwise the bottom of a
        // tall tab is clipped by the dialog and the inner scroll never reaches it.
        double windowHeight = Root.XamlRoot.Size.Height;
        var presenter = new ContentPresenter
        {
            Height = Math.Clamp(windowHeight - 230, 180, 420),
            Margin = new Thickness(0, 8, 0, 0),
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        foreach (var (header, content) in tabs)
            bar.Items.Add(new SelectorBarItem { Text = header, Tag = content });
        bar.SelectionChanged += (s, _) => presenter.Content = s.SelectedItem?.Tag;
        bar.SelectedItem = bar.Items[0];
        presenter.Content = tabs[0].Content;

        var body = new StackPanel { Width = 440 };
        body.Children.Add(bar);
        body.Children.Add(presenter);

        var dialog = new ContentDialog
        {
            Title = "Settings",
            Content = body,
            CloseButtonText = "Close",
            XamlRoot = Root.XamlRoot,
        };
        await ShowDialogAsync(dialog);
    }

    // MARK: - Tab builders

    private FrameworkElement BuildGeneralTab()
    {
        var panel = NewTabPanel();

        var formatCombo = LabeledCombo("Format",
            new[] { ("PNG", "png"), ("JPEG", "jpeg"), ("HEIC", "heic") },
            _screenshotFormat,
            tag => { _screenshotFormat = tag; SaveSettings(); });

        var askToggle = Toggle("Ask save location every time", !_screenshotAutoSave, askEveryTime =>
        {
            _screenshotAutoSave = !askEveryTime;
            SaveSettings();
        });

        var dirLabel = new TextBlock
        {
            Text = _screenshotDirectory ?? "~\\Pictures",
            Opacity = 0.6,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var chooseButton = new Button { Content = "Choose..." };
        chooseButton.Click += async (_, _) =>
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            StorageFolder? folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;
            _screenshotDirectory = folder.Path;
            dirLabel.Text = folder.Path;
            SaveSettings();
        };
        var dirRow = new Grid { ColumnSpacing = 10 };
        dirRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        dirRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(dirLabel, 0);
        Grid.SetColumn(chooseButton, 1);
        dirRow.Children.Add(dirLabel);
        dirRow.Children.Add(chooseButton);

        panel.Children.Add(Section("Screenshot",
            new FrameworkElement[] { formatCombo, askToggle, dirRow },
            "Image format used when saving screenshots. When save location isn't " +
            "asked every time, screenshots are written straight to the folder below."));

        var monitorCombo = LabeledCombo("Monitor",
            new[] { ("24 kHz (Dedicated)", NativeApi.Monitor24kHz.ToString()),
                    ("15 kHz (Standard)", NativeApi.Monitor15kHz.ToString()) },
            _monitorType.ToString(),
            tag => { _monitorType = int.Parse(tag); SaveSettings(); });

        var memoryWaitToggle = Toggle("Memory wait", _memoryWaitDip, on =>
        {
            _memoryWaitDip = on;
            SaveSettings();
        });

        var extRamCombo = LabeledCombo("Extended RAM",
            new[] { ("None", "0"), ("128 KB", "1"), ("1 MB", "8") },
            _extRamCards.ToString(),
            tag => { _extRamCards = int.Parse(tag); SaveSettings(); });

        panel.Children.Add(Section("Hardware Configuration", new FrameworkElement[]
        {
            monitorCombo,
            Caption("DIP SW1-8 on real hardware. The monitor's horizontal frequency decides " +
                    "the VSYNC rate: 55.4 Hz at 24 kHz, 62.4 Hz at 15 kHz. Applied on next reset."),
            memoryWaitToggle,
            Caption("DIP SW1-6 on real hardware. Adds one wait state to main memory and text " +
                    "VRAM accesses, slowing the machine slightly. Off on a factory-default " +
                    "PC-8801. Applied on next reset."),
            extRamCombo,
            Caption("Applied on next reset."),
        }));

        var updateToggle = Toggle("Check for updates at launch", _automaticUpdateCheck, on =>
        {
            _automaticUpdateCheck = on;
            SaveSettings();
        });
        panel.Children.Add(Section("Updates", new FrameworkElement[] { updateToggle },
            "Looks for a newer release on GitHub at most once a day."));

        panel.Children.Add(BuildAutomationSettings());

        return panel;
    }

    private FrameworkElement BuildDisplayTab()
    {
        var panel = NewTabPanel();

        var caption = Caption(FullscreenScalingCaption());
        RadioButton ScalingRadio(string label, FullscreenScaling mode)
        {
            var r = new RadioButton { Content = label, GroupName = "Scaling", IsChecked = _fullscreenScaling == mode };
            r.Checked += (_, _) => { _fullscreenScaling = mode; ApplyIntegerScaling(); SaveSettings(); caption.Text = FullscreenScalingCaption(); };
            return r;
        }
        var fit = ScalingRadio("Fit to Screen", FullscreenScaling.Fit);
        var integer = ScalingRadio("Integer Scaling", FullscreenScaling.Integer);
        var aspect43 = ScalingRadio("Correct Aspect Ratio (4:3)", FullscreenScaling.Aspect43);

        panel.Children.Add(Section("Fullscreen", new[] { (FrameworkElement)fit, integer, aspect43, caption }));

        var model = AIModelStore.Quality;
        var modelStatus = Caption(AIModelStore.Shared.IsInstalled(model)
            ? "Quality (Real-ESRGAN x2): downloaded"
            : "Quality (Real-ESRGAN x2): not downloaded");
        var deleteModel = new Button
        {
            Content = "Delete downloaded model",
            IsEnabled = AIModelStore.Shared.IsInstalled(model),
        };
        deleteModel.Click += async (_, _) =>
        {
            deleteModel.IsEnabled = false;
            try
            {
                if (_videoFilter == "AIQuality")
                {
                    _videoFilter = "None";
                    SaveSettings();
                    SyncVideoFilterMenu();
                    ApplyVideoFilter();
                }
                if (_screen is not null) await _screen.ReleaseAiModelAsync(model.Name);
                AIModelStore.Shared.Remove(model);
                modelStatus.Text = "Quality (Real-ESRGAN x2): not downloaded";
            }
            catch (Exception ex)
            {
                modelStatus.Text = $"Could not delete model: {ex.Message}";
                deleteModel.IsEnabled = true;
            }
        };
        panel.Children.Add(Section("AI Model", new FrameworkElement[] { modelStatus, deleteModel }));
        return panel;
    }

    private FrameworkElement BuildAudioTab()
    {
        var panel = NewTabPanel();

        var value = new TextBlock
        {
            Text = $"{_audioBufferMs} ms",
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 52,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
        };
        var slider = new Slider
        {
            Minimum = 20, Maximum = 500, StepFrequency = 20,
            Value = _audioBufferMs, Width = 260,
        };
        slider.ValueChanged += (_, ev) =>
        {
            _audioBufferMs = (int)ev.NewValue;
            if (_host is not null) _host.AudioBufferMs = _audioBufferMs;
            value.Text = $"{_audioBufferMs} ms";
            SaveSettings();
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(value);
        row.Children.Add(slider);

        panel.Children.Add(Section("Audio Buffer", new[] { (FrameworkElement)row },
            "Lower values reduce latency but may cause crackling."));

        var pseudoStereoToggle = Toggle("Enable Pseudo Stereo", _pseudoStereo, isOn =>
        {
            _pseudoStereo = isOn;
            _host?.SetPseudoStereo(isOn);
            SaveSettings();
        });
        panel.Children.Add(Section("Pseudo Stereo", new[] { (FrameworkElement)pseudoStereoToggle },
            "Widens mono FM/SSG output with a Haas-effect chorus. Has no effect once any FM channel uses hardware panning."));

        var cdMixToggle = Toggle("Enable CD Mix", _cdMix, isOn =>
        {
            _cdMix = isOn;
            _host?.SetCdMix(isOn);
            SaveSettings();
        });
        panel.Children.Add(Section("CD Mix", new[] { (FrameworkElement)cdMixToggle },
            "Recreates the mastering of classic game music CDs."));

        var fddToggle = Toggle("Enable FDD Sound", _fddSoundEnabled, isOn =>
        {
            _fddSoundEnabled = isOn;
            if (isOn)
            {
                _fddSound?.Start(_fddSoundDeviceId);
            }
            else
            {
                _fddSound?.Stop();
            }
            SaveSettings();
        });
        var fddVolume = LabeledCombo("Volume",
            new[] { ("Low", "0"), ("Medium", "1"), ("High", "2") },
            _fddSoundVolumeLevel.ToString(),
            tag =>
            {
                _fddSoundVolumeLevel = int.Parse(tag);
                if (_fddSound is not null) _fddSound.Volume = FddSound.VolumeForLevel(_fddSoundVolumeLevel);
                SaveSettings();
            });

        // Output-device picker — mirrors macOS's SettingsView "Output Device"
        // Picker (fddDeviceBinding), which lets FDD sound target a different
        // physical device than the main YM2608 audio. Populated live each time
        // the Settings dialog opens, matching the macOS `.task` device refresh.
        var devices = AudioDeviceList.OutputDevices();
        var fddDevice = LabeledCombo("Output Device",
            devices.ConvertAll(d => (d.Name, d.Id)).ToArray(),
            _fddSoundDeviceId,
            deviceId =>
            {
                _fddSoundDeviceId = deviceId;
                _fddSound?.ApplyOutputDevice(deviceId);
                SaveSettings();
            });

        panel.Children.Add(Section("FDD Sound", new FrameworkElement[] { fddToggle, fddVolume, fddDevice },
            "Synthesized floppy disk seek and read sounds with stereo drive separation."));

        return panel;
    }

    private FrameworkElement BuildKeyboardTab()
    {
        var panel = NewTabPanel();

        var detected = Caption(DetectedLayoutCaption());
        var layoutCombo = LabeledCombo("Keyboard Layout",
            new[] { ("Auto-detect", "auto"), ("JIS", "jis"), ("US (ANSI)", "us") },
            _keyboardLayout,
            tag => { _keyboardLayout = tag; ApplyKeyboardConfig(); SaveSettings(); detected.Text = DetectedLayoutCaption(); });
        panel.Children.Add(Section("Layout", new[] { (FrameworkElement)layoutCombo, detected }));

        var arrows = NumpadToggle("Arrow Keys as Numpad",
            "Maps arrow keys to numpad 8/2/4/6 for game character movement.",
            _arrowKeysAsNumpad, v => { _arrowKeysAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });
        var numbers = NumpadToggle("Number Row as Numpad",
            "Maps number row 0-9 to numpad 0-9 (e.g. adventure-game menu selections).",
            _numberRowAsNumpad, v => { _numberRowAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });
        var wasd = NumpadToggle("WASD as Numpad",
            "Maps WASD to numpad 8/4/2/6 for left-hand character movement.",
            _wasdAsNumpad, v => { _wasdAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });

        panel.Children.Add(Section("Numpad Emulation", new[] { arrows, numbers, wasd }));
        return panel;
    }

    private FrameworkElement BuildControllerTab()
    {
        var panel = NewTabPanel();

        var countCaption = Caption(ControllerCountCaption());
        var enableToggle = Toggle("Enable Game Controller", _gameControllerEnabled, isOn =>
        {
            _gameControllerEnabled = isOn;
            _controller.Enabled = isOn;
            SaveSettings();
            countCaption.Text = ControllerCountCaption();
        });
        panel.Children.Add(Section("Game Controller", new[] { (FrameworkElement)enableToggle, countCaption },
            "Xbox/PlayStation/Switch-style pads recognized by Windows as a standard gamepad. " +
            "Dpad and left stick both drive the same directions."));

        var rows = new StackPanel { Spacing = 8 };
        var mappingSection = Section("Button Mapping", new FrameworkElement[] { rows });
        panel.Children.Add(mappingSection);

        List<Action> refreshRow = new();
        foreach (ControllerButton button in Enum.GetValues<ControllerButton>())
        {
            var row = BuildMappingRow(button, out Action refresh);
            rows.Children.Add(row);
            refreshRow.Add(refresh);
        }

        var resetButton = new Button { Content = "Reset to Defaults" };
        resetButton.Click += (_, _) =>
        {
            _controllerMapping = ControllerButtonMapping.Defaults.Clone();
            _controller.Mapping = _controllerMapping;
            SaveSettings();
            foreach (var refresh in refreshRow) refresh();
        };
        panel.Children.Add(resetButton);

        return panel;
    }

    private string ControllerCountCaption()
    {
        int n = _controller.ConnectedCount;
        return n == 0 ? "No controller connected." : $"{n} controller(s) connected.";
    }

    /// <summary>One "Button  [binding]  [Bind] [Clear]" row. Only Pc88Key
    /// bindings are user-assignable via the capture flow (matches macOS, where
    /// pc88Key bindings likewise only exist as hardcoded defaults / are not
    /// reachable from the "press a key" UI) — Clear always sets None.</summary>
    private FrameworkElement BuildMappingRow(ControllerButton button, out Action refresh)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = new TextBlock { Text = button.ToString(), VerticalAlignment = VerticalAlignment.Center };
        var binding = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Opacity = 0.8 };
        var bind = new Button { Content = "Bind…", MinWidth = 64 };
        var clear = new Button { Content = "Clear", MinWidth = 56 };

        void UpdateText() => binding.Text = MappingLabel(_controllerMapping.Action(button));
        UpdateText();
        refresh = UpdateText;

        // Capture the next key directly on the Bind button rather than at the
        // window's Root.KeyDown: a ContentDialog opens in the popup layer, so
        // keyboard focus (and routed KeyDown bubbling) stays within the dialog's
        // own visual tree and never reaches Root while the dialog is open.
        // AddHandler(..., handledEventsToo: true) is required (not plain +=):
        // a focused Button otherwise consumes Space/Enter itself (re-invoking
        // Click) and arrow keys for focus navigation before a normal handler
        // would see them, which would make exactly those keys unbindable.
        // Escape still closes the dialog (ContentDialog's own accelerator runs
        // first) — binding to Escape isn't possible from this flow.
        bind.Click += (_, _) =>
        {
            binding.Text = "Press a key…";
            bind.Focus(FocusState.Programmatic);

            KeyEventHandler? handler = null;
            handler = (s, e) =>
            {
                bind.RemoveHandler(UIElement.KeyDownEvent, handler);
                if (KeyMapping.TryMap(e.Key, out var matrix))
                {
                    _controllerMapping.Buttons[button.ToString()] = ButtonAction.Pc88(new MappedKey(matrix.Row, matrix.Bit));
                    _controller.Mapping = _controllerMapping;
                    SaveSettings();
                }
                UpdateText();
                e.Handled = true;
            };
            bind.AddHandler(UIElement.KeyDownEvent, handler, handledEventsToo: true);
        };
        clear.Click += (_, _) =>
        {
            _controllerMapping.Buttons[button.ToString()] = ButtonAction.None;
            _controller.Mapping = _controllerMapping;
            SaveSettings();
            UpdateText();
        };

        Grid.SetColumn(label, 0);
        Grid.SetColumn(binding, 1);
        Grid.SetColumn(bind, 2);
        Grid.SetColumn(clear, 3);
        grid.Children.Add(label);
        grid.Children.Add(binding);
        grid.Children.Add(bind);
        grid.Children.Add(clear);
        return grid;
    }

    private static string MappingLabel(ButtonAction action) => action.Kind switch
    {
        ButtonActionKind.Pc88Key => KeyMapping.TryReverseLookup(new KeyMapping.MatrixKey(action.Key.Row, action.Key.Bit), out var vk)
            ? vk.ToString()
            : $"Key({action.Key.Row},{action.Key.Bit})",
        ButtonActionKind.HostCommand => action.Command.ToString(),
        _ => "—",
    };

    // MARK: - Dynamic caption text

    private string FullscreenScalingCaption()
        => _fullscreenScaling switch
        {
            FullscreenScaling.Integer => "Pixel-perfect display with black borders. No scaling artifacts.",
            FullscreenScaling.Aspect43 => "Stretch vertically by 1.2 to match the pixel shape of 4:3 monitors. Edges stay sharp.",
            _ => "Fill the screen as much as possible while maintaining aspect ratio.",
        };

    private static string DetectedLayoutCaption()
        => $"Detected: {(KeyMapping.EffectiveLayout() == KeyMapping.KbLayout.Jis ? "JIS" : "US (ANSI)")}";

    // MARK: - UI helpers

    private static ScrollViewer WrapTab(FrameworkElement content)
        => new()
        {
            Content = content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            Padding = new Thickness(2, 8, 12, 8),
        };

    private static StackPanel NewTabPanel()
        => new() { Spacing = 18, Margin = new Thickness(0, 4, 0, 4) };

    private static StackPanel Section(string title, IEnumerable<FrameworkElement> children, string? caption = null)
    {
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold });
        foreach (var c in children) panel.Children.Add(c);
        if (caption is not null) panel.Children.Add(Caption(caption));
        return panel;
    }

    private static StackPanel Section(string title, FrameworkElement child, string? caption = null)
        => Section(title, new[] { child }, caption);

    private static TextBlock Caption(string text)
        => new() { Text = text, Opacity = 0.6, FontSize = 12, TextWrapping = TextWrapping.Wrap };

    /// A "Label  [ ComboBox ]" row whose options are (display, tag) pairs; invokes
    /// <paramref name="onPick"/> with the chosen tag.
    private static Grid LabeledCombo(string label, (string Text, string Tag)[] options,
                                     string current, Action<string> onPick)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(text, 0);

        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        int selected = 0;
        for (int i = 0; i < options.Length; i++)
        {
            combo.Items.Add(new ComboBoxItem { Content = options[i].Text, Tag = options[i].Tag });
            if (options[i].Tag == current) selected = i;
        }
        combo.SelectedIndex = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem item && item.Tag is string tag) onPick(tag);
        };
        Grid.SetColumn(combo, 1);

        grid.Children.Add(text);
        grid.Children.Add(combo);
        return grid;
    }

    /// A checkbox bound to an on/off callback — the shared building block
    /// behind both <see cref="NumpadToggle"/> and standalone toggles like the
    /// Audio tab's "Enable FDD Sound" checkbox.
    private static CheckBox Toggle(string label, bool isOn, Action<bool> onToggle)
    {
        var check = new CheckBox { Content = label, IsChecked = isOn };
        check.Checked += (_, _) => onToggle(true);
        check.Unchecked += (_, _) => onToggle(false);
        return check;
    }

    /// A checkbox + caption pair for the numpad-emulation toggles.
    private static StackPanel NumpadToggle(string label, string caption, bool isOn, Action<bool> onToggle)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(Toggle(label, isOn, onToggle));
        panel.Children.Add(Caption(caption));
        return panel;
    }
}
