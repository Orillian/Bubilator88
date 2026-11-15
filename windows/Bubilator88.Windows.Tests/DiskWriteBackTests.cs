using System;
using System.IO;
using System.Linq;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class DiskWriteBackTests : IDisposable
{
    private sealed class Machine : IDiskWriteBackMachine
    {
        public readonly byte[]?[] Dirty = new byte[2][];
        public int Written;
        public int Takes;
        public int Marked;
        public readonly int[] TakesByDrive = new int[2];
        public int? FailTakeDrive;
        public bool Locked;
        public Action? AfterPoll;
        public Action? AfterUnlock;
        public void WithDiskLock(Action action)
        {
            bool wasLocked = Locked;
            Locked = true;
            try { action(); }
            finally
            {
                Locked = wasLocked;
                if (!wasLocked) { AfterUnlock?.Invoke(); AfterUnlock = null; }
            }
        }
        public int TakeDiskWritten() { int bits = Written; Written = 0; AfterPoll?.Invoke(); return bits; }
        public byte[]? TakeDirtyDisk(int drive)
        {
            Takes++;
            TakesByDrive[drive]++;
            if (FailTakeDrive == drive) throw new IOException("Snapshot failed.");
            var b = Dirty[drive]; Dirty[drive] = null; return b;
        }
        public void MarkDiskDirty(int drive) => Marked |= 1 << drive;
    }

    private readonly string _directory = Path.Combine(Path.GetTempPath(), "b88-disks-" + Guid.NewGuid().ToString("N"));
    private readonly Machine _machine = new();
    private readonly DriveSlot[] _slots = { new(), new() };
    public DiskWriteBackTests() => Directory.CreateDirectory(_directory);
    public void Dispose() => Directory.Delete(_directory, recursive: true);
    private DiskWriteBack Create() => new(_machine, _slots, Path.Combine(_directory, "recovery"));
    private string Mount(int drive = 0, int index = 0)
    {
        string path = Path.Combine(_directory, "game.d88");
        if (!File.Exists(path)) File.WriteAllBytes(path, DiskWriteBackIOTests.Bank(1).Concat(DiskWriteBackIOTests.Bank(2)).ToArray());
        _slots[drive].Fill(File.ReadAllBytes(path), "game.d88", new[]
        { new EmulatorHost.ImageInfo("A", "2D", false), new EmulatorHost.ImageInfo("B", "2D", false) }, index, path);
        return path;
    }

    [Fact]
    public void Tick_ContinuousWrites_WaitsUntil100msAfterLastNotification()
    {
        string path = Mount();
        var writer = Create();
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        for (int i = 0; i < 20; i++)
        {
            _machine.Written = 1;
            writer.Tick(i * 0.05);
            Assert.Equal(0, _machine.Takes);
        }
        writer.Tick(1.04);
        Assert.Equal(0, _machine.Takes);
        writer.Tick(1.06);
        Assert.Equal(DiskWriteBackIOTests.Bank(3).Concat(DiskWriteBackIOTests.Bank(2)), File.ReadAllBytes(path));
    }

    [Fact]
    public void FlushAll_WithoutPolling_SavesBothBanksAndRefreshesSwitchBuffers()
    {
        string path = Mount();
        Mount(1, 1);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3, 0x300);
        _machine.Dirty[1] = DiskWriteBackIOTests.Bank(4);
        Create().FlushAll();
        byte[] expected = DiskWriteBackIOTests.Bank(3, 0x300).Concat(DiskWriteBackIOTests.Bank(4)).ToArray();
        Assert.Equal(expected, File.ReadAllBytes(path));
        Assert.Equal(expected, _slots[0].Bytes);
        Assert.Equal(expected, _slots[1].Bytes);
    }

    [Fact]
    public void Tick_WriteArrivesDuringQuietCheck_DoesNotSnapshotAnActiveWriteBurst()
    {
        string path = Mount();
        var writer = Create();
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        _machine.Written = 1;
        writer.Tick(0);
        _machine.AfterPoll = () =>
        {
            void Write() { _machine.Dirty[0] = DiskWriteBackIOTests.Bank(4); _machine.Written = 1; }
            if (_machine.Locked) _machine.AfterUnlock = Write;
            else Write();
        };

        writer.Tick(0.2);

        Assert.Equal(DiskWriteBackIOTests.Bank(3).Concat(DiskWriteBackIOTests.Bank(2)), File.ReadAllBytes(path));
        Assert.Equal(DiskWriteBackIOTests.Bank(4), _machine.Dirty[0]);
        Assert.Equal(1, _machine.Written);
    }

    [Fact]
    public void Tick_SecondSnapshotFails_RestoresFirstDrivesDirtyState()
    {
        Mount();
        Mount(1, 1);
        var writer = Create();
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        _machine.Dirty[1] = DiskWriteBackIOTests.Bank(4);
        _machine.Written = 3;
        writer.Tick(0);
        _machine.FailTakeDrive = 1;
        Assert.Throws<IOException>(() => writer.Tick(0.2));
        Assert.Equal(1, _machine.Marked & 1);
    }

    [Fact]
    public void Flush_SourceWriteFails_RecoversBankAndRestoresDirtyForRetry()
    {
        string path = Mount();
        var writer = Create();
        string? warning = null;
        writer.Warning = value => warning = value;
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None)) writer.Flush(0);
        Assert.Equal(1, _machine.Marked);
        Assert.Contains("recovery", warning);
        string recovered = Assert.Single(Directory.GetFiles(Path.Combine(_directory, "recovery")));
        Assert.Equal(DiskWriteBackIOTests.Bank(3), File.ReadAllBytes(recovered));
        Assert.Equal(DiskWriteBackIOTests.Bank(3).Concat(DiskWriteBackIOTests.Bank(2)), _slots[0].Bytes!);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        writer.Flush(0);
        Assert.Equal(_slots[0].Bytes, File.ReadAllBytes(path));
    }

    [Fact]
    public void Flush_CorruptSource_RecoversChangesAndKeepsDirtyForRetry()
    {
        string path = Mount();
        byte[] corrupt = new byte[0x30];
        File.WriteAllBytes(path, corrupt);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);

        Create().Flush(0);

        Assert.Equal(1, _machine.Marked);
        Assert.Equal(corrupt, File.ReadAllBytes(path));
        string recovery = Assert.Single(Directory.GetFiles(Path.Combine(_directory, "recovery")));
        Assert.Equal(DiskWriteBackIOTests.Bank(3), File.ReadAllBytes(recovery));
    }

    [Fact]
    public void BeforeMediaChange_OnlyFlushesAffectedDriveAndHoldsMachineLock()
    {
        string path = Mount();
        Mount(1, 1);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        _machine.Dirty[1] = DiskWriteBackIOTests.Bank(4);

        int result = Create().BeforeMediaChange(1, () =>
        {
            Assert.True(_machine.Locked);
            Assert.Equal(DiskWriteBackIOTests.Bank(3).Concat(DiskWriteBackIOTests.Bank(2)), File.ReadAllBytes(path));
            return 42;
        });

        Assert.Equal(42, result);
        Assert.Equal(DiskWriteBackIOTests.Bank(4), _machine.Dirty[1]);
    }

    [Fact]
    public void BeforeMediaChange_NestedBatch_DoesNotFlushSameDriveRepeatedly()
    {
        Mount();
        var writer = Create();
        writer.BeforeMediaChange(3, () =>
        {
            writer.BeforeMediaChange(1, () => true);
            writer.BeforeMediaChange(2, () => true);
            return true;
        });
        Assert.Equal(new[] { 1, 1 }, _machine.TakesByDrive);
    }

    [Fact]
    public void BeforeMediaChange_NoWritableDestination_DoesNotReplaceDiskAndRestoresTransactionScope()
    {
        string path = Mount();
        string recovery = Path.Combine(_directory, "recovery");
        File.WriteAllText(recovery, "not a directory");
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        var writer = Create();
        bool replaced = false;
        using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => writer.BeforeMediaChange(1, () => replaced = true));
        Assert.False(replaced);
        Assert.False(_machine.Locked);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(4);
        writer.BeforeMediaChange(1, () => replaced = true);
        Assert.True(replaced);
        Assert.Equal(DiskWriteBackIOTests.Bank(4).Concat(DiskWriteBackIOTests.Bank(2)), File.ReadAllBytes(path));
    }

    [Fact]
    public void Flush_NoSourcePath_WritesRecoveryInsteadOfLosingChanges()
    {
        Mount();
        _slots[0].SourcePath = null;
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        Create().Flush(0);
        string recovered = Assert.Single(Directory.GetFiles(Path.Combine(_directory, "recovery")));
        Assert.Equal(DiskWriteBackIOTests.Bank(3), File.ReadAllBytes(recovered));
    }

    [Fact]
    public void Flush_MissingMultiImageSource_RecoversBankWithoutChangingItsIndex()
    {
        string path = Mount(index: 1);
        File.Delete(path);
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        Create().Flush(0);
        Assert.False(File.Exists(path));
        string recovered = Assert.Single(Directory.GetFiles(Path.Combine(_directory, "recovery")));
        Assert.Equal(DiskWriteBackIOTests.Bank(3), File.ReadAllBytes(recovered));
        Assert.Equal(DiskWriteBackIOTests.Bank(1).Concat(DiskWriteBackIOTests.Bank(3)), _slots[0].Bytes!);
        Assert.Equal(1, _slots[0].CurrentImage);
    }

    [Fact]
    public void Flush_SourceAndRecoveryFail_ThrowsAndKeepsDiskDirty()
    {
        string path = Mount();
        string recovery = Path.Combine(_directory, "recovery");
        File.WriteAllText(recovery, "blocks creation of directory");
        _machine.Dirty[0] = DiskWriteBackIOTests.Bank(3);
        using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => Create().Flush(0));
        Assert.Equal(1, _machine.Marked);
    }

    [Fact]
    public void Flush_CleanOrWriteProtectedDisk_DoesNotRewriteFile()
    {
        string path = Mount();
        DateTime original = File.GetLastWriteTimeUtc(path);
        _slots[0].WriteProtected = true;
        Create().FlushAll();
        Assert.Equal(original, File.GetLastWriteTimeUtc(path));
        Assert.False(Directory.Exists(Path.Combine(_directory, "recovery")));
    }
}
