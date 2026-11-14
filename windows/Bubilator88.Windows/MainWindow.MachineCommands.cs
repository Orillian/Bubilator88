using System;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>Application commands shared by normal UI and AutomationHost.
/// Machine replacements remain quiescent through metadata and display updates.</summary>
public sealed partial class MainWindow : IEmulatorAppCommands
{
    bool IEmulatorAppCommands.IsRunning => !_paused;
    void IEmulatorAppCommands.SetRunning(bool running) => SetEmulatorRunning(running);
    void IEmulatorAppCommands.PublishFrame() => PublishCurrentFrame();
    void IEmulatorAppCommands.Reset(EmulatorBootMode? mode, bool? clock8MHz) => ResetMachine(mode, clock8MHz);
    string IEmulatorAppCommands.MountDisk(int drive, string path, int imageIndex, bool writeProtected) =>
        MountDiskFile(drive, path, imageIndex, writeProtected);
    void IEmulatorAppCommands.EjectDisk(int drive) => EjectDrive(drive);
    void IEmulatorAppCommands.SaveState(string path) => SaveStateFile(path);
    void IEmulatorAppCommands.LoadState(string path) => LoadStateFile(path);

    private PausedMachineOperation PausedOperation => new(() => !_paused, SetEmulatorRunning);

    private void ResetMachine(EmulatorBootMode? mode = null, bool? clockOverride = null)
    {
        if (_host is null) return;
        PausedOperation.Run(() =>
        {
            if (mode is not null) _bootModeIndex = (int)mode;
            ApplyBootConfig(preserveRam: true, clockOverride: clockOverride);
            _sliceIndex = 0;
            (_bootModeIndex switch { 1 => BootN88V1H, 2 => BootN88V1S, 3 => BootNBasic, _ => BootN88V2 }).IsChecked = true;
            SaveSettings();
            PublishCurrentFrame();
        });
    }

    private string MountDiskFile(int drive, string path, int imageIndex = 0, bool writeProtected = false)
    {
        byte[] bytes = File.ReadAllBytes(path);
        if (_host!.ProbeDisk(bytes, out var images) <= 0) throw new InvalidDataException("Not a D88 disk image.");
        return MountDiskExplicit(drive, bytes, Path.GetFileName(path), images, imageIndex, path, writeProtected);
    }

    private string MountDiskExplicit(int drive, byte[] bytes, string name, EmulatorHost.ImageInfo[] images,
        int imageIndex, string? sourcePath, bool writeProtected = false)
    {
        if (imageIndex < 0 || imageIndex >= images.Length) throw new ArgumentOutOfRangeException(nameof(imageIndex));
        bool protect = images[imageIndex].WriteProtected || writeProtected;
        if (_host!.MountDiskProtected(drive, bytes, imageIndex, protect) <= 0)
            throw new InvalidDataException("Cannot mount the disk image.");
        FillSlot(_drives[drive], bytes, name, images, imageIndex, sourcePath, writeProtected: protect);
        if (sourcePath is not null) AddRecent(sourcePath);
        RebuildDiskMenu();
        UpdateDiskStatus();
        return images[imageIndex].Name;
    }

    private void SaveStateFile(string path)
    {
        if (_host is not { } host) throw new InvalidOperationException("The emulator is unavailable.");
        PausedOperation.Run(() =>
        {
            byte[] blob = host.WithMachine(() =>
            {
                host.Render(blinkCursor: true);
                byte[] thumbnail = StateSections.EncodeThumbnail(host.Pixels);
                var metadata = BuildMeta();
                metadata.Clock8MHz = host.Clock8MHz;
                return host.SaveState(metadata, thumbnail);
            });
            if (blob.Length == 0) throw new InvalidDataException("Cannot serialize the save state.");
            AtomicStateFile.Write(path, blob);
        });
    }

    private void LoadStateFile(string path)
    {
        if (_host is not { } host) throw new InvalidOperationException("The emulator is unavailable.");
        byte[] blob = File.ReadAllBytes(path);
        var metadata = StateSections.ReadMetadata(blob, path);
        PausedOperation.Run(() =>
        {
            host.WithMachine(() =>
            {
                if (!host.LoadState(blob)) throw new InvalidDataException("Corrupt or incompatible save state.");
                _controller.ReleaseAll(host);
                host.ReleaseAllKeys();
                ApplyLoadedMeta(metadata, persist: false);
                RestoreDiskLabels(host);
                _sliceIndex = 0;
                PublishCurrentFrame();
                return true;
            });
            SaveSettings();
        });
    }

    private void RestoreDiskLabels(EmulatorHost host)
    {
        for (int i = 0; i < 2; i++)
        {
            if (!host.HasDisk(i)) { _drives[i] = new DriveSlot(); continue; }
            if (!_drives[i].Occupied)
            {
                string name = host.DiskName(i);
                _drives[i] = ReconstructDrive(i, new WinSaveMeta.DriveMeta
                { FileName = name, ImageNames = new[] { name }, ImageCount = 1 });
            }
            _drives[i].WriteProtected = host.IsWriteProtected(i);
        }
        RebuildDiskMenu();
        UpdateDiskStatus();
    }
}
