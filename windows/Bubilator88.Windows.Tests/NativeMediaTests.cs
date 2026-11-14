using System;
using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;

namespace Bubilator88.Windows
{
    // Only native context lifetime is supplied by this harness. All disk,
    // protection, state serialization and section methods are source-linked
    // from the production EmulatorHost.Media.cs, without audio/WinUI services.
    internal sealed unsafe partial class EmulatorHost : IDisposable
    {
        public readonly object SyncRoot = new();
        private IntPtr _handle = NativeApi.b88_create();
        public void Dispose() => NativeApi.b88_destroy(_handle);
    }
}

namespace Bubilator88.Windows.Tests
{
    internal static class NativeMcpLibrary
    {
        private static readonly object Gate = new();
        private static bool _initialized;
        public static void Initialize()
        {
            lock (Gate)
            {
                if (_initialized) return;
                string? path = Environment.GetEnvironmentVariable("B88_MCP_TEST_DLL");
                if (string.IsNullOrWhiteSpace(path)) return;
                IntPtr library = NativeLibrary.Load(path);
                NativeLibrary.SetDllImportResolver(typeof(NativeApi).Assembly,
                    (name, _, _) => name == "Bubilator88C" ? library : IntPtr.Zero);
                _initialized = true;
            }
        }
    }

    public sealed class NativeMediaTests
    {
        static NativeMediaTests() => NativeMcpLibrary.Initialize();

        [NativeMcpFact]
        public async Task ProtectedMount_ConcurrentObserversNeverSeeWritableDisk()
        {
            using var host = new EmulatorHost();
            byte[] image = new byte[0x2b0];
            BinaryPrimitives.WriteInt32LittleEndian(image.AsSpan(0x1c), image.Length);
            Assert.Equal(1, host.MountDiskProtected(0, image, 0, true));
            var reader = Task.Run(() =>
            {
                for (int i = 0; i < 1000; i++)
                    lock (host.SyncRoot)
                        if (host.HasDisk(0)) Assert.True(host.IsWriteProtected(0));
            });
            try
            {
                for (int i = 0; i < 1000; i++) Assert.Equal(1, host.MountDiskProtected(0, image, 0, true));
            }
            finally { await reader; }
        }

        [NativeMcpFact]
        public void SingleFileState_EmbeddedMetadataAndThumbnailOverrideLegacySidecars()
        {
            string directory = Path.Combine(Path.GetTempPath(), "b88-state-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "state.b88s");
            using var host = new EmulatorHost();
            try
            {
                var metadata = new WinSaveMeta { BootModeIndex = 1, Clock8MHz = true, MonitorType = 0 };
                byte[] png = StateSections.EncodeThumbnail(new byte[640 * 400 * 4]);
                byte[] blob = host.SaveState(metadata, png);
                AtomicStateFile.Write(path, blob);
                File.WriteAllText(Path.ChangeExtension(path, ".meta.json"), JsonSerializer.Serialize(new WinSaveMeta { BootModeIndex = 3 }));
                File.WriteAllText(Path.ChangeExtension(path, ".thumb.png"), "stale preview");
                byte[] copiedFile = File.ReadAllBytes(path);
                Assert.Equal(1, StateSections.ReadMetadata(copiedFile, path)!.BootModeIndex);
                Assert.Equal(0, StateSections.ReadMetadata(copiedFile, path)!.MonitorType);
                Assert.Equal(png, StateSections.ReadThumbnail(copiedFile, path));
                Assert.True(host.LoadState(copiedFile));
                Assert.Contains("\"bootMode\":\"n88-v1h\"", Encoding.UTF8.GetString(StateSections.Read(copiedFile, StateSections.AppMeta)!));
            }
            finally { Directory.Delete(directory, recursive: true); }
        }

        [NativeMcpFact]
        public void LegacyState_ReadsWindowsMetadataAndThumbnailSidecars()
        {
            string directory = Path.Combine(Path.GetTempPath(), "b88-state-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "state.b88s");
            using var host = new EmulatorHost();
            try
            {
                byte[] blob = host.SaveState();
                File.WriteAllBytes(path, blob);
                File.WriteAllText(Path.ChangeExtension(path, ".meta.json"), JsonSerializer.Serialize(new WinSaveMeta { BootModeIndex = 2 }));
                byte[] png = { 1, 2, 3 };
                File.WriteAllBytes(Path.ChangeExtension(path, ".thumb.png"), png);
                Assert.Equal(2, StateSections.ReadMetadata(blob, path)!.BootModeIndex);
                Assert.Equal(png, StateSections.ReadThumbnail(blob, path));
                Assert.True(host.LoadState(blob));
            }
            finally { Directory.Delete(directory, recursive: true); }
        }
    }
}
