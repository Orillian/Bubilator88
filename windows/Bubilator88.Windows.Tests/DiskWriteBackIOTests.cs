using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class DiskWriteBackIOTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "b88-writeback-" + Guid.NewGuid().ToString("N"));
    public DiskWriteBackIOTests() => Directory.CreateDirectory(_directory);
    public void Dispose() => Directory.Delete(_directory, recursive: true);

    internal static byte[] Bank(byte value, int length = 0x2b0)
    {
        var bank = Enumerable.Repeat(value, length).ToArray();
        BinaryPrimitives.WriteInt32LittleEndian(bank.AsSpan(0x1c), length);
        return bank;
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void WriteBank_MultiImageFile_PreservesOtherBanksAndHandlesSizeChanges(int index)
    {
        byte[][] banks = { Bank(1), Bank(2), Bank(3) };
        string path = Path.Combine(_directory, "multi.d77");
        File.WriteAllBytes(path, banks.SelectMany(b => b).ToArray());
        byte[] replacement = Bank(4, 0x300);

        DiskWriteBackIO.WriteBank(path, index, replacement);

        banks[index] = replacement;
        Assert.Equal(banks.SelectMany(b => b), File.ReadAllBytes(path));
    }

    [Fact]
    public void WriteBank_SequentialWritesToSharedFile_PreserveBothDrivesChanges()
    {
        string path = Path.Combine(_directory, "shared.d88");
        File.WriteAllBytes(path, Bank(1).Concat(Bank(2)).ToArray());
        DiskWriteBackIO.WriteBank(path, 0, Bank(3, 0x300));
        DiskWriteBackIO.WriteBank(path, 1, Bank(4));
        Assert.Equal(Bank(3, 0x300).Concat(Bank(4)), File.ReadAllBytes(path));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void WriteBank_CorruptExistingFile_DoesNotOverwriteIt(int index)
    {
        string path = Path.Combine(_directory, "corrupt.d88");
        byte[] corrupt = new byte[0x30];
        File.WriteAllBytes(path, corrupt);
        Assert.Throws<InvalidDataException>(() => DiskWriteBackIO.WriteBank(path, index, Bank(1)));
        Assert.Equal(corrupt, File.ReadAllBytes(path));
    }

    [Fact]
    public void WriteBank_MissingFile_CreatesSingleBankImage()
    {
        string path = Path.Combine(_directory, "missing.d88");
        DiskWriteBackIO.WriteBank(path, 0, Bank(1), allowCreate: true);
        Assert.Equal(Bank(1), File.ReadAllBytes(path));
    }

    [Fact]
    public void WriteBank_MissingMultiImageFile_DoesNotRecreateItAsOneBank()
    {
        string path = Path.Combine(_directory, "missing-multi.d88");
        Assert.Throws<FileNotFoundException>(() => DiskWriteBackIO.WriteBank(path, 1, Bank(1)));
        Assert.False(File.Exists(path));
    }

    [Fact]
    public void WriteBank_LockedExistingFile_DoesNotTruncateIt()
    {
        string path = Path.Combine(_directory, "locked.d88");
        File.WriteAllBytes(path, Bank(1));
        using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => DiskWriteBackIO.WriteBank(path, 0, Bank(2)));
        Assert.Equal(Bank(1), File.ReadAllBytes(path));
    }

    [Fact]
    public void WriteRecovery_InvalidFileNameAndRepeatedWrites_ProducesDistinctUsableFiles()
    {
        string first = DiskWriteBackIO.WriteRecovery(_directory, "game:bad/name", 0, Bank(1));
        string second = DiskWriteBackIO.WriteRecovery(_directory, "game:bad/name", 0, Bank(2));
        Assert.NotEqual(first, second);
        Assert.Equal(_directory, Path.GetDirectoryName(first));
        Assert.Equal(Bank(1), File.ReadAllBytes(first));
        Assert.Equal(Bank(2), File.ReadAllBytes(second));
    }
}
