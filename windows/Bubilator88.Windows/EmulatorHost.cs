using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Windows.System;

namespace Bubilator88.Windows;

/// <summary>
/// Managed lifetime wrapper around one native <c>B88Context</c>. Owns the
/// reusable pixel + audio scratch buffers so the per-frame path never
/// allocates.
///
/// <para>The core must only be touched by one thread at a time. The emulation
/// thread (<see cref="EmulationLoop"/>) and the UI thread both call in, so every
/// native call takes <see cref="SyncRoot"/>. The lock is re-entrant, so a
/// caller may hold it across several calls to make them one step (the loop's
/// tick does).</para>
/// </summary>
internal sealed unsafe partial class EmulatorHost : IDisposable
{
    /// <summary>Serializes every access to the native context (see the class remarks).</summary>
    public readonly object SyncRoot = new();

    public const int ScreenWidth = 640;
    public const int ScreenHeight = 400;
    private const int PixelBytes = ScreenWidth * ScreenHeight * 4;
    private const int AudioMaxPairs = 4096;
    private const int SampleRate = 44100;

    /// <summary>Peak |sample| of the most recent audio drain (0..1), for a UI level meter.</summary>
    public float LastPeak { get; private set; }

    /// <summary>
    /// Target output-buffer latency in milliseconds (20–500) for the adaptive
    /// rate control — the Windows analogue of the macOS audio ring-buffer size
    /// (Settings.audioBufferMs). Lower values cut latency but risk crackling;
    /// the default (100 ms) matches macOS. Adjusted live from the Settings dialog.
    /// </summary>
    public int AudioBufferMs { get; set; } = 100;

    private IntPtr _handle;

    // Pre-allocated, reused every frame (zero per-frame GC pressure).
    private readonly byte[] _pixels = new byte[PixelBytes];
    private readonly float[] _audio = new float[AudioMaxPairs * 2];

    /// <summary>
    /// The buffer <see cref="Render"/> composites into. Only read it while
    /// holding <see cref="SyncRoot"/>; the UI takes finished frames from the
    /// <see cref="FramePublisher"/> instead.
    /// </summary>
    public ReadOnlySpan<byte> Pixels => _pixels;

    public EmulatorHost()
    {
        _handle = NativeApi.b88_create();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("b88_create returned null — is Bubilator88C.dll present?");
    }

    /// <summary>
    /// Load ROM files from <paramref name="romDir"/> (defaults to
    /// %LOCALAPPDATA%\Bubilator88). N88.ROM is required; the rest are optional.
    /// </summary>
    public void LoadRoms(string? romDir = null)
    {
        lock (SyncRoot) LoadRomsLocked(romDir);
    }

    private void LoadRomsLocked(string? romDir)
    {
        romDir ??= Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Bubilator88");

        LoadRom(romDir, "N88.ROM", NativeApi.RomN88, required: true);
        LoadRom(romDir, "N80.ROM", NativeApi.RomN80);
        LoadRom(romDir, "DISK.ROM", NativeApi.RomDisk);
        LoadRom(romDir, "FONT.ROM", NativeApi.RomFont);
        // The kanji ROMs fall back to the bundled Shinonome-based substitutes.
        LoadRom(romDir, "KANJI1.ROM", NativeApi.RomKanji1, substitute: "SubstituteKANJI1.ROM");
        LoadRom(romDir, "KANJI2.ROM", NativeApi.RomKanji2, substitute: "SubstituteKANJI2.ROM");
        LoadRom(romDir, "JISYO.ROM", NativeApi.RomJisyo);
        for (int bank = 0; bank < 4; bank++)
            LoadRom(romDir, $"N88_{bank}.ROM", NativeApi.RomN88Ext0 + bank);

        LoadRhythmSamples(romDir);
    }

    private void LoadRhythmSamples(string dir)
    {
        foreach (var (index, data) in RhythmSampleFiles.Load(dir))
        {
            fixed (byte* p = data)
                NativeApi.b88_load_rhythm_sample(_handle, index, p, data.Length);
        }
    }

    private void LoadRom(string dir, string name, int kind, bool required = false,
                         string? substitute = null)
    {
        string path = Path.Combine(dir, name);
        if (!File.Exists(path))
        {
            if (required)
                throw new FileNotFoundException($"Required ROM missing: {path}");
            if (substitute is null || DeploymentFiles.Find(substitute) is not string bundled)
                return;
            path = bundled;
        }
        byte[] data = File.ReadAllBytes(path);
        fixed (byte* p = data)
            NativeApi.b88_load_rom(_handle, kind, p, data.Length);
    }

    /// <summary>Enable/disable the pseudo-stereo (Haas effect) chorus on mono FM/SSG. Survives Reset/Configure.</summary>
    public void SetPseudoStereo(bool enabled)
    {
        lock (SyncRoot) NativeApi.b88_set_pseudo_stereo(_handle, enabled ? 1 : 0);
    }

    public void SetCdMix(bool enabled)
    {
        lock (SyncRoot) NativeApi.b88_set_cd_mix(_handle, enabled ? 1 : 0);
    }

    /// <summary>
    /// Sample and clear the per-drive disk-access flags (drives 0 and 1).
    /// Each flag pulses true while the FDC touched that drive since the last
    /// call — drive the status-bar activity LEDs from it.
    /// </summary>
    public void SampleDiskAccess(out bool drive0, out bool drive1)
    {
        int a = 0, b = 0;
        lock (SyncRoot) NativeApi.b88_disk_access(_handle, &a, &b);
        drive0 = a != 0;
        drive1 = b != 0;
    }

    /// <summary>
    /// Sample and clear the per-drive FDD *sound* events — kept distinct from
    /// <see cref="SampleDiskAccess"/> so the two synthesized sounds
    /// (<see cref="FddSound"/>) can be triggered independently, matching macOS.
    /// <paramref name="seek0"/>/<paramref name="seek1"/> are COUNTS: a
    /// multi-track seek can step several times within one sampled (~16.7ms)
    /// frame, and macOS plays one click per step with no throttling, so the
    /// host must replay that many clicks rather than collapsing to one.
    /// <paramref name="access0"/>/<paramref name="access1"/> stay booleans —
    /// <see cref="FddSound"/>'s 30ms per-drive throttle already exceeds one
    /// frame's duration, so a count would never produce more than one hit.
    /// </summary>
    public void SampleFddSoundEvents(out int seek0, out int seek1, out bool access0, out bool access1)
    {
        int s0 = 0, s1 = 0, a0 = 0, a1 = 0;
        lock (SyncRoot) NativeApi.b88_fdd_sound_events(_handle, &s0, &s1, &a0, &a1);
        seek0 = s0;
        seek1 = s1;
        access0 = a0 != 0;
        access1 = a1 != 0;
    }

    /// <summary>
    /// Configure boot mode and reset. Mount disks BEFORE calling so the boot
    /// strap (DIP SW2 bit 3) picks FDD boot when drive 0 is occupied.
    /// </summary>
    public void Configure(bool clock8MHz, int dipSw1, int dipSw2Base, bool preserveRam = false,
                          int extRamCards = NativeApi.ExtRam_128KB,
                          int monitorType = NativeApi.Monitor24kHz, bool memoryWaitDip = false)
    {
        lock (SyncRoot)
        {
        NativeApi.b88_set_dipsw1(_handle, dipSw1);
        NativeApi.b88_apply_bootstrap(_handle, dipSw2Base);
        // Set before the reset: the monitor decides the CRTC's reset geometry
        // (and so the frame rate) — same ordering as macOS performReset.
        NativeApi.b88_set_monitor_type(_handle, monitorType);
        NativeApi.b88_set_memory_wait_dip(_handle, memoryWaitDip ? 1 : 0);
        // Cold reset (clear RAM) only for the first boot; user-triggered
        // re-applies (Reset / boot mode / clock) preserve RAM, matching the
        // macOS performReset (machine.reset(preserveRAM: true)).
        NativeApi.b88_reset(_handle, preserveRam ? 1 : 0);
        // Set the clock AFTER reset: Machine.reset() forces clock8MHz = true,
        // so configuring the clock before the reset would be clobbered back to
        // 8 MHz. This mirrors the macOS ordering in EmulatorViewModel (reset,
        // then assign clock8MHz).
        NativeApi.b88_set_clock_8mhz(_handle, clock8MHz ? 1 : 0);
        // Re-install extended RAM last, fresh (zeroed) every reset — mirrors
        // macOS's loadROMs() call at the end of performReset, which reinstalls
        // extRAM from Settings.extramCards on every reset.
        NativeApi.b88_install_ext_ram(_handle, extRamCards);
        }
    }

    public void Reset(bool preserveRam = false) { lock (SyncRoot) NativeApi.b88_reset(_handle, preserveRam ? 1 : 0); }

    /// <summary>
    /// Re-sync the DIP switches to a boot mode WITHOUT resetting. Used after a
    /// save-state load (which doesn't serialize DIP switches) so a subsequent
    /// Reset stays consistent with the restored boot mode — mirrors the macOS
    /// performLoad DIP re-sync.
    /// </summary>
    public void SyncDip(int dipSw1, int dipSw2Base)
    {
        lock (SyncRoot)
        {
            NativeApi.b88_set_dipsw1(_handle, dipSw1);
            NativeApi.b88_apply_bootstrap(_handle, dipSw2Base);
        }
    }

    /// <summary>True if the restored/active CPU clock is 8 MHz.</summary>
    public bool Clock8MHz { get { lock (SyncRoot) return NativeApi.b88_get_clock_8mhz(_handle) != 0; } }

    /// <summary>
    /// Monitor the machine is running on (NativeApi.Monitor15kHz/24kHz) — the
    /// one applied at the last reset, which can differ from the pending setting.
    /// Setting it takes effect without a reset; used to restore a save state.
    /// </summary>
    public int MonitorType
    {
        get { lock (SyncRoot) return NativeApi.b88_get_monitor_type(_handle); }
        set { lock (SyncRoot) NativeApi.b88_set_monitor_type(_handle, value); }
    }

    /// <summary>
    /// Memory wait DIP (SW1-6) the machine is running with. Setting it takes
    /// effect without a reset; used to restore a save state.
    /// </summary>
    public bool MemoryWaitDip
    {
        get { lock (SyncRoot) return NativeApi.b88_get_memory_wait_dip(_handle) != 0; }
        set { lock (SyncRoot) NativeApi.b88_set_memory_wait_dip(_handle, value ? 1 : 0); }
    }

    /// <summary>
    /// Extended RAM cards installed now (NativeApi.ExtRam_*). A save state
    /// brings its own extended RAM, so this can differ from the setting.
    /// </summary>
    public int ExtRamCards { get { lock (SyncRoot) return NativeApi.b88_get_ext_ram_cards(_handle); } }

    /// <summary>
    /// True if the machine is in native 400-line mode; false for 200-line
    /// (the renderer row-doubles it to 640×400). Video filters use this to pick
    /// the content resolution they operate on.
    /// </summary>
    public bool Is400Line { get { lock (SyncRoot) return NativeApi.b88_is_400line(_handle) != 0; } }

    private byte[][] _cheatCodes = Array.Empty<byte[]>();

    /// <summary>The enabled 88PAR groups (packed, see <see cref="PatFile.Pack"/>),
    /// run once before every frame.</summary>
    public void SetCheatCodes(IReadOnlyList<byte[]> groups)
    {
        lock (SyncRoot) _cheatCodes = groups.ToArray();
    }

    /// <summary>Run the enabled cheat groups once. Caller holds <see cref="SyncRoot"/>,
    /// between frames.</summary>
    private void ApplyCheats()
    {
        foreach (byte[] group in _cheatCodes)
            fixed (byte* p = group)
                NativeApi.b88_pat_run(_handle, p, group.Length / PatFile.PackedCodeSize);
    }

    /// <summary>Advance the machine by one 1/60s frame (no rendering).</summary>
    public void RunFrame()
    {
        lock (SyncRoot)
        {
            ApplyCheats();
            NativeApi.b88_run_frame(_handle);
        }
    }

    /// <summary>
    /// Run slice <paramref name="index"/> of <paramref name="count"/> roughly
    /// equal slices of the current frame (mirrors macOS's
    /// <c>runFrameSliceForMetal</c>). Returns true once the frame has ended —
    /// the caller should drain audio after every call regardless, but only
    /// render/present and reset the slice index when this returns true.
    /// </summary>
    public bool RunFrameSlice(int index, int count)
    {
        lock (SyncRoot)
        {
            if (index == 0) ApplyCheats();   // once per frame, before it starts
            return NativeApi.b88_run_frame_slice(_handle, index, count) != 0;
        }
    }

    /// <summary>
    /// Emulated VSYNC frequency in Hz, from the CRTC programming (55.42Hz on
    /// a 24kHz monitor). Falls back to 60 before the CRTC is set up.
    /// </summary>
    public double FrameRate
    {
        get
        {
            double rate;
            lock (SyncRoot) rate = NativeApi.b88_frame_rate(_handle);
            return rate > 0 ? rate : 60.0;
        }
    }

    /// <summary>Composite the current machine state into the internal pixel buffer.</summary>
    public void Render(bool blinkCursor)
    {
        lock (SyncRoot)
            fixed (byte* p = _pixels)
                NativeApi.b88_render_rgba(_handle, p, _pixels.Length, blinkCursor ? 1 : 0);
    }

    /// <summary>Run one frame and composite into the internal pixel buffer.</summary>
    public void RunFrameAndRender(bool blinkCursor)
    {
        RunFrame();
        Render(blinkCursor);
    }

    /// <summary>
    /// Drain available audio into <paramref name="sink"/>. Returns pairs drained.
    /// </summary>
    public int DrainAudio(XAudioSink sink)
    {
        lock (SyncRoot) return DrainAudioLocked(sink);
    }

    private int DrainAudioLocked(XAudioSink sink)
    {
        int pairs;
        fixed (float* p = _audio)
            pairs = NativeApi.b88_drain_audio(_handle, p, AudioMaxPairs);
        if (pairs > 0)
        {
            sink.Submit(_audio, pairs * 2);

            float peak = 0f;
            int n = pairs * 2;
            for (int i = 0; i < n; i++)
            {
                float a = Math.Abs(_audio[i]);
                if (a > peak) peak = a;
            }
            // Decay so the meter falls smoothly between bursts.
            LastPeak = peak > LastPeak ? peak : LastPeak * 0.85f;
        }
        else
        {
            LastPeak *= 0.85f;
        }

        // Keep XAudio2's queued latency near the configured target so the
        // producer (60 Hz frame loop) and consumer (44.1 kHz device) don't drift.
        // b88_audio_rate_control steers bufferedFrames toward capacityFrames / 2,
        // so pass target * 2 here (mirrors macOS's AudioOutput.finishDrain:
        // `pc88.adjustAudioRate(bufferedFrames: fill, capacityFrames: target * 2)`).
        int targetPairs = (int)(SampleRate * (Math.Clamp(AudioBufferMs, 20, 500) / 1000.0));
        NativeApi.b88_audio_rate_control(_handle, sink.QueuedPairs, targetPairs * 2);
        return pairs;
    }

    /// <summary>Press a key. Returns true if the key mapped to the matrix.</summary>
    public bool KeyDown(VirtualKey key)
    {
        if (!KeyMapping.TryMap(key, out var m)) return false;
        lock (SyncRoot) NativeApi.b88_press_key(_handle, m.Row, m.Bit);
        return true;
    }

    /// <summary>Release a key. Returns true if the key mapped to the matrix.</summary>
    public bool KeyUp(VirtualKey key)
    {
        if (!KeyMapping.TryMap(key, out var m)) return false;
        lock (SyncRoot) NativeApi.b88_release_key(_handle, m.Row, m.Bit);
        return true;
    }

    /// <summary>Press a PC-88 matrix cell directly, bypassing VirtualKey mapping.
    /// Used by the game-controller path, whose inputs aren't Windows VirtualKeys.</summary>
    public void PressMatrixKey(int row, int bit) { lock (SyncRoot) NativeApi.b88_press_key(_handle, row, bit); }

    /// <summary>Release a PC-88 matrix cell directly. See <see cref="PressMatrixKey"/>.</summary>
    public void ReleaseMatrixKey(int row, int bit) { lock (SyncRoot) NativeApi.b88_release_key(_handle, row, bit); }

    public void ReleaseAllKeys() { lock (SyncRoot) NativeApi.b88_release_all_keys(_handle); }

    public void Dispose()
    {
        lock (SyncRoot)
        {
            if (_handle != IntPtr.Zero)
            {
                NativeApi.b88_destroy(_handle);
                _handle = IntPtr.Zero;
            }
        }
        GC.SuppressFinalize(this);
    }

    /// <summary>Create a separate MCP session; its requests acquire the machine
    /// lock through host callbacks rather than holding it across UI dispatch.</summary>
    public IntPtr CreateAppMcpSession(NativeApi.McpAppCallbacks callbacks, string version)
    {
        lock (SyncRoot)
        {
            ObjectDisposedException.ThrowIf(_handle == IntPtr.Zero, this);
            return NativeApi.CreateAppMcpSession(_handle, callbacks, version);
        }
    }

    public int InvokeMachineAction(Func<int> action)
        => WithMachine(action);

    public T WithMachine<T>(Func<T> action)
    {
        lock (SyncRoot)
        {
            ObjectDisposedException.ThrowIf(_handle == IntPtr.Zero, this);
            return action();
        }
    }

    /// <summary>Discard sound produced by host frames run while paused.</summary>
    public void DiscardAudio()
    {
        lock (SyncRoot)
        {
            fixed (float* audio = _audio)
                while (NativeApi.b88_drain_audio(_handle, audio, AudioMaxPairs) > 0) { }
        }
    }

}
