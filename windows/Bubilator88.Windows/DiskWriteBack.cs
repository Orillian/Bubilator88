using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.ExceptionServices;

namespace Bubilator88.Windows;

internal interface IDiskWriteBackMachine
{
    void WithDiskLock(Action action);
    int TakeDiskWritten();
    byte[]? TakeDirtyDisk(int drive);
    void MarkDiskDirty(int drive);
}

/// <summary>UI-thread disk persistence. Bursts debounce for 100ms without a hard deadline,
/// so a BASIC SAVE cannot flush a partially updated FAT. Replacement and shutdown flush explicitly.</summary>
internal sealed class DiskWriteBack
{
    private const int DriveCount = 2;
    private const int AllDrives = (1 << DriveCount) - 1;
    private readonly IDiskWriteBackMachine _machine;
    private readonly DriveSlot[] _slots;
    private readonly string _recoveryDirectory;
    private readonly double?[] _due = new double?[DriveCount];
    private int _changingDrives;
    public Action<string>? Warning { get; set; }

    public DiskWriteBack(IDiskWriteBackMachine machine, DriveSlot[] slots, string recoveryDirectory)
    { _machine = machine; _slots = slots; _recoveryDirectory = recoveryDirectory; }

    /// <summary>Flushes only the drives being replaced, then keeps replacement and
    /// metadata changes under the machine lock. Nested batch operations flush each drive once.</summary>
    public T BeforeMediaChange<T>(int drives, Func<T> operation)
    {
        T result = default!;
        _machine.WithDiskLock(() =>
        {
            int parentDrives = _changingDrives;
            try
            {
                _changingDrives |= drives;
                PersistSnapshots(TakeSnapshots(() => drives & ~parentDrives));
                result = operation();
            }
            finally { _changingDrives = parentDrives; }
        });
        return result;
    }

    public void Tick(double now) => PersistSnapshots(TakeSnapshots(() =>
    {
        int written = _machine.TakeDiskWritten();
        int ready = 0;
        for (int drive = 0; drive < DriveCount; drive++)
        {
            if ((written & (1 << drive)) != 0) _due[drive] = now + 0.1;
            if (_due[drive] is double due && now >= due) ready |= 1 << drive;
        }
        return ready;
    }));

    /// <summary>Checks native dirty state even if its write notification has not been polled yet.</summary>
    public void FlushAll() => PersistSnapshots(TakeSnapshots(() => AllDrives));
    public void Flush(int drive) => PersistSnapshots(TakeSnapshots(() => 1 << drive));

    private byte[]?[] TakeSnapshots(Func<int> selectDrives)
    {
        byte[]?[] snapshots = new byte[DriveCount][];
        try
        {
            // No sector write may land between the quiet-time check and capture.
            // Tick releases this lock before file I/O; a media transaction retains its outer lock.
            _machine.WithDiskLock(() =>
            {
                int selected = selectDrives();
                for (int drive = 0; drive < DriveCount; drive++)
                {
                    if ((selected & (1 << drive)) == 0) continue;
                    _due[drive] = null;
                    snapshots[drive] = _machine.TakeDirtyDisk(drive);
                }
            });
        }
        catch
        {
            // None have been persisted yet. Restore every successful take before propagating.
            for (int drive = 0; drive < DriveCount; drive++)
                if (snapshots[drive] is not null) _machine.MarkDiskDirty(drive);
            throw;
        }
        return snapshots;
    }

    private void PersistSnapshots(byte[]?[] snapshots)
    {
        List<Exception>? failures = null;
        List<string>? warnings = null;
        for (int drive = 0; drive < DriveCount; drive++)
        {
            if (snapshots[drive] is not { } bank) continue;
            try
            {
                if (WriteSnapshot(drive, bank) is { } warning) (warnings ??= new()).Add(warning);
            }
            catch (Exception error)
            {
                // Preserve dirty state even for an unexpected exception, and still attempt
                // every other snapshot that has already been removed from native dirty state.
                _machine.MarkDiskDirty(drive);
                (failures ??= new()).Add(error);
            }
        }
        // Notification failures must not be interpreted as file failures or prevent another save.
        if (warnings is not null)
            foreach (string warning in warnings) Warning?.Invoke(warning);
        if (failures is { Count: 1 }) ExceptionDispatchInfo.Capture(failures[0]).Throw();
        if (failures is not null) throw new AggregateException("Disk changes could not be saved.", failures);
    }

    private string? WriteSnapshot(int drive, byte[] bank)
    {
        var slot = _slots[drive];
        Exception? sourceError = null;
        byte[]? merged = null;
        if (slot.SourcePath is string path)
        {
            try
            {
                // The read itself decides whether creation is allowed; no File.Exists race.
                merged = DiskWriteBackIO.WriteBank(path, slot.CurrentImage, bank,
                    allowCreate: slot.ImageCount == 1 && slot.CurrentImage == 0);
            }
            catch (Exception error) when (IsStorageError(error))
            {
                _machine.MarkDiskDirty(drive);
                sourceError = error;
            }
        }

        string? warning = null;
        if (merged is null)
        {
            string recovery;
            try { recovery = DiskWriteBackIO.WriteRecovery(_recoveryDirectory, slot.FileName, drive, bank); }
            catch (Exception error) when (IsStorageError(error))
            {
                throw new IOException($"Disk write failed: {sourceError?.Message ?? "No source file."}\nRecovery failed: {error.Message}", error);
            }
            warning = sourceError is null ? $"Disk changes saved to {recovery}"
                : $"Disk write failed: {sourceError.Message}\nDisk changes saved to {recovery}";
        }

        if (merged is not null) RefreshBuffers(slot, merged);
        else if (slot.Bytes is { Length: > 0 } original)
        {
            try { RefreshBuffers(slot, DiskWriteBackIO.ReplaceBank(original, slot.CurrentImage, bank)); }
            catch (InvalidDataException) { /* A recovered bank cannot reconstruct an unavailable multi-bank file. */ }
        }
        return warning;
    }

    private static bool IsStorageError(Exception error) =>
        error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or NotSupportedException;

    private void RefreshBuffers(DriveSlot slot, byte[] merged)
    {
        slot.Bytes = merged;
        if (slot.SourcePath is not string path) return;
        foreach (var other in _slots)
            if (other.SourcePath is string otherPath && SamePath(path, otherPath)) other.Bytes = merged;
    }

    private static bool SamePath(string first, string second)
    {
        try { return string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase); }
        catch (Exception error) when (IsStorageError(error)) { return false; }
    }
}
