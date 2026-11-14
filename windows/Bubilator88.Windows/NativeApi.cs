using System;
using System.Runtime.InteropServices;

namespace Bubilator88.Windows;

/// <summary>
/// P/Invoke bindings for the Swift emulation core (Bubilator88C.dll, built from
/// Sources/CApi/ in bubio/Bubilator88Core, split across several files). This is the ONLY boundary
/// between the managed shell and the native core — every signature here must
/// match a <c>@_cdecl</c> export exactly.
///
/// All buffer-passing entry points take raw pointers so the hot path (render /
/// audio drain) is zero-copy and allocation-free — see the GC notes in
/// docs/develop/WINDOWS_PORT.md. We use <see cref="LibraryImportAttribute"/> (source
/// generated, blittable-only) to avoid the classic Marshal copy.
/// </summary>
internal static unsafe partial class NativeApi
{
    // App-owned MCP sessions. Keep the delegate alive through session_destroy.
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int McpMachineAction(IntPtr actionData);

    [LibraryImport(Dll)]
    public static partial int b88_mcp_session_handle(IntPtr session, byte* json, int length);

    [LibraryImport(Dll)]
    public static partial int b88_mcp_session_reply(IntPtr session, byte* output, int capacity);

    [LibraryImport(Dll)]
    public static partial void b88_mcp_session_destroy(IntPtr session);

    [LibraryImport(Dll)]
    public static partial int b88_disk_name(IntPtr handle, int drive, byte* output, int capacity);

    [LibraryImport(Dll)]
    public static partial int b88_is_write_protected(IntPtr handle, int drive);

    [LibraryImport(Dll)]
    public static partial int b88_encode_png(byte* pixels, int length, int width, int height, byte* output, int capacity);

    [LibraryImport(Dll)]
    public static partial int b88_save_state_ex(IntPtr handle, byte* thumbnail, int thumbnailLength, byte* extra, int extraLength);

    [LibraryImport(Dll)]
    public static partial int b88_state_section(byte* data, int length, uint tag, byte* output, int capacity);

    [LibraryImport(Dll)]
    public static partial void b88_release_all_keys(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial int b88_mount_disk_protected(IntPtr handle, int drive, byte* data, int length, int imageIndex, int writeProtected);

    private const string Dll = "Bubilator88C";

    // ROM kind selectors for b88_load_rom.
    public const int RomN88 = 0;
    public const int RomN80 = 1;
    public const int RomDisk = 2;
    public const int RomFont = 3;
    public const int RomKanji1 = 4;
    public const int RomKanji2 = 5;
    public const int RomJisyo = 6;
    public const int RomN88Ext0 = 10; // +0..+3 for banks 0..3

    // DIP SW2 base values (boot mode).
    public const int DipSw2_V2 = 0x71;
    public const int DipSw2_V1H = 0xF1;
    public const int DipSw2_V1S = 0xB1;
    // DIP SW1.
    public const int DipSw1_N88 = 0xC3;
    public const int DipSw1_NBasic = 0xC2;

    // Extended RAM capacity, for b88_install_ext_ram (matches Settings.extramCards on macOS).
    public const int ExtRam_None = 0;
    public const int ExtRam_128KB = 1;
    public const int ExtRam_1MB = 8;

    [LibraryImport(Dll)]
    public static partial IntPtr b88_create();

    [LibraryImport(Dll)]
    public static partial void b88_destroy(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial void b88_load_rom(IntPtr handle, int kind, byte* ptr, int len);

    // index: 0=BD 1=SD 2=TOP 3=HH 4=TOM 5=RIM. ptr/len is the raw 2608_*.WAV blob.
    [LibraryImport(Dll)]
    public static partial void b88_load_rhythm_sample(IntPtr handle, int index, byte* ptr, int len);

    [LibraryImport(Dll)]
    public static partial int b88_mount_disk(IntPtr handle, int drive, byte* ptr, int len, int imageIndex);

    [LibraryImport(Dll)]
    public static partial void b88_eject_disk(IntPtr handle, int drive);

    [LibraryImport(Dll)]
    public static partial void b88_set_write_protect(IntPtr handle, int drive, int protected_);

    [LibraryImport(Dll)]
    public static partial void b88_set_pseudo_stereo(IntPtr handle, int enabled);

    [LibraryImport(Dll)]
    public static partial void b88_set_cd_mix(IntPtr handle, int enabled);

    [LibraryImport(Dll)]
    public static partial int b88_d88_probe(byte* ptr, int len, byte* outUtf8, int outCap);

    [LibraryImport(Dll)]
    public static partial void b88_set_dipsw1(IntPtr handle, int value);

    [LibraryImport(Dll)]
    public static partial void b88_apply_bootstrap(IntPtr handle, int dipsw2Base);

    [LibraryImport(Dll)]
    public static partial void b88_reset(IntPtr handle, int preserveRam);

    // cards: 0=none, 1=128KB, 8=1MB. Re-installs a fresh (zeroed) buffer, so
    // call after b88_reset, matching the macOS reset ordering.
    [LibraryImport(Dll)]
    public static partial void b88_install_ext_ram(IntPtr handle, int cards);

    // Extended RAM cards installed right now (0/1/8). A save state carries its
    // own extended RAM, so this is read back after a load.
    [LibraryImport(Dll)]
    public static partial int b88_get_ext_ram_cards(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial void b88_set_clock_8mhz(IntPtr handle, int on);

    [LibraryImport(Dll)]
    public static partial int b88_get_clock_8mhz(IntPtr handle);

    // Monitor type (SW1-8), MonitorType raw values. Decides the CRTC's reset
    // geometry and the frame rate (15kHz = 62.42Hz, 24kHz = 55.42Hz), so set
    // it before b88_reset.
    public const int Monitor15kHz = 0;
    public const int Monitor24kHz = 1;

    [LibraryImport(Dll)]
    public static partial void b88_set_monitor_type(IntPtr handle, int type);

    [LibraryImport(Dll)]
    public static partial int b88_get_monitor_type(IntPtr handle);

    // Memory wait DIP (SW1-6). Set before b88_reset, alongside the monitor.
    [LibraryImport(Dll)]
    public static partial void b88_set_memory_wait_dip(IntPtr handle, int on);

    [LibraryImport(Dll)]
    public static partial int b88_get_memory_wait_dip(IntPtr handle);

    // CPU-only overclock (1 = real speed); CRTC/sound/RTC keep real time.
    [LibraryImport(Dll)]
    public static partial void b88_set_cpu_overclock(IntPtr handle, int multiplier);

    // 1 = native 400-line, 0 = 200-line (doubled). Lets the host feed video
    // filters the correct content resolution (640×200 vs 640×400).
    [LibraryImport(Dll)]
    public static partial int b88_is_400line(IntPtr handle);

    // Save state. b88_save_state builds + stashes the blob and returns its length;
    // b88_save_state_read copies it out. b88_load_state returns 1 on success.
    [LibraryImport(Dll)]
    public static partial int b88_save_state(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial int b88_save_state_read(IntPtr handle, byte* outPtr, int outCap);

    [LibraryImport(Dll)]
    public static partial int b88_load_state(IntPtr handle, byte* ptr, int len);

    [LibraryImport(Dll)]
    public static partial int b88_run_frame(IntPtr handle);

    // Apply one group of 88PAR cheat codes once: `count` codes of 6 bytes each
    // (opcode, area, address LE16, value LE16). Call between frames, from the
    // thread that runs them. Needs a core with b88_pat_run (1.4.0+).
    [LibraryImport(Dll)]
    public static partial void b88_pat_run(IntPtr handle, byte* codes, int count);

    // Run slice `index` of `count` slices of the current frame. Returns 1 once
    // the frame has ended (render then, and start the next frame at slice 0),
    // 0 if it hasn't, -1 for a bad handle or an index outside 0..<count. Pace
    // the calls at `count × frame rate` and drain audio after each one — see
    // CApi.swift's b88_run_frame_slice doc comment.
    [LibraryImport(Dll)]
    public static partial int b88_run_frame_slice(IntPtr handle, int index, int count);

    // VSYNC frequency in Hz (55.42 on a 24kHz monitor, 62.42 on 15kHz — never
    // exactly 60). Follows the CRTC, so re-read every frame. 0 = not set up.
    [LibraryImport(Dll)]
    public static partial double b88_frame_rate(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial void b88_press_key(IntPtr handle, int row, int bit);

    [LibraryImport(Dll)]
    public static partial void b88_release_key(IntPtr handle, int row, int bit);

    [LibraryImport(Dll)]
    public static partial int b88_render_rgba(IntPtr handle, byte* outPtr, int outLen, int blinkCursor);

    [LibraryImport(Dll)]
    public static partial int b88_drain_audio(IntPtr handle, float* outPtr, int maxPairs);

    [LibraryImport(Dll)]
    public static partial void b88_audio_rate_control(IntPtr handle, int fillPairs, int capacityPairs);

    [LibraryImport(Dll)]
    public static partial void b88_disk_access(IntPtr handle, int* out0, int* out1);

    // Distinct seek-step (COUNT, since several steps can land in one sampled
    // frame) / read-access (0/1 pulse) events per drive, for the two
    // synthesized FDD sounds (mechanical click vs. buzz) — see b88_disk_access
    // for the combined flag the status-bar LEDs use instead.
    [LibraryImport(Dll)]
    public static partial void b88_fdd_sound_events(IntPtr handle, int* seek0, int* seek1, int* access0, int* access1);
}
