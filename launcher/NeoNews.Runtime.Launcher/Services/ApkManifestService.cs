using System.IO.Compression;
using System.Text;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record ApkManifestMetadata(
    string PackageName,
    string? VersionName,
    long? VersionCode);

/// <summary>
/// Reads the small set of identity fields needed before an APK is installed.
/// AndroidManifest.xml is normally binary AXML, so this intentionally avoids
/// depending on a global Android SDK/aapt installation.
/// </summary>
public static class ApkManifestService
{
    private const ushort XmlChunkType = 0x0003;
    private const ushort StringPoolChunkType = 0x0001;
    private const ushort StartElementChunkType = 0x0102;
    private const uint NoIndex = 0xFFFFFFFF;
    private const byte TypedString = 0x03;
    private const byte TypedIntDecimal = 0x10;
    private const byte TypedIntHex = 0x11;

    public static ApkManifestMetadata Read(string apkPath)
    {
        using var archive = ZipFile.OpenRead(apkPath);
        var manifestEntry = archive.GetEntry("AndroidManifest.xml")
            ?? throw new InvalidDataException("O APK não contém AndroidManifest.xml.");
        using var stream = manifestEntry.Open();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return ReadBinaryXml(memory.ToArray());
    }

    private static ApkManifestMetadata ReadBinaryXml(byte[] data)
    {
        if (data.Length < 8 || ReadUInt16(data, 0) != XmlChunkType)
            throw new InvalidDataException("AndroidManifest.xml não está no formato AXML esperado.");

        var xmlHeaderSize = ReadUInt16(data, 2);
        var xmlSize = CheckedSize(ReadUInt32(data, 4), data.Length, 0);
        if (xmlHeaderSize < 8 || xmlHeaderSize > xmlSize)
            throw new InvalidDataException("Cabeçalho XML AXML inválido.");

        var stringPool = ReadStringPool(data, xmlHeaderSize, xmlSize);
        var offset = checked(xmlHeaderSize + CheckedSize(ReadUInt32(data, xmlHeaderSize + 4), data.Length, xmlHeaderSize));
        string? packageName = null;
        string? versionName = null;
        long? versionCode = null;

        while (offset + 8 <= xmlSize)
        {
            var chunkType = ReadUInt16(data, offset);
            var chunkHeaderSize = ReadUInt16(data, offset + 2);
            var chunkSize = CheckedSize(ReadUInt32(data, offset + 4), xmlSize, offset);
            if (chunkHeaderSize < 8 || chunkHeaderSize > chunkSize || chunkSize == 0)
                throw new InvalidDataException($"Chunk AXML inválido em 0x{offset:X}.");

            if (chunkType == StartElementChunkType)
            {
                ReadManifestAttributes(
                    data,
                    offset,
                    chunkHeaderSize,
                    chunkSize,
                    stringPool,
                    ref packageName,
                    ref versionName,
                    ref versionCode);
            }

            offset = checked(offset + chunkSize);
        }

        if (string.IsNullOrWhiteSpace(packageName))
            throw new InvalidDataException("AndroidManifest.xml não contém o atributo package.");

        return new ApkManifestMetadata(packageName, versionName, versionCode);
    }

    private static StringPool ReadStringPool(byte[] data, int offset, int xmlSize)
    {
        if (offset + 28 > xmlSize || ReadUInt16(data, offset) != StringPoolChunkType)
            throw new InvalidDataException("String pool AXML ausente ou inválido.");

        var headerSize = ReadUInt16(data, offset + 2);
        var chunkSize = CheckedSize(ReadUInt32(data, offset + 4), xmlSize, offset);
        if (headerSize < 28 || headerSize > chunkSize)
            throw new InvalidDataException("Cabeçalho da string pool AXML inválido.");

        var stringCount = CheckedCount(ReadUInt32(data, offset + 8));
        var flags = ReadUInt32(data, offset + 16);
        var stringsStart = CheckedSize(ReadUInt32(data, offset + 20), chunkSize, 0);
        var offsetsStart = checked(offset + headerSize);
        var offsetsEnd = checked(offsetsStart + stringCount * 4);
        if (offsetsEnd > offset + chunkSize || offset + stringsStart > offset + chunkSize)
            throw new InvalidDataException("Offsets da string pool AXML estão fora do chunk.");

        var stringOffsets = new int[stringCount];
        for (var index = 0; index < stringCount; index++)
        {
            var relativeOffset = CheckedSize(ReadUInt32(data, offsetsStart + index * 4), chunkSize - stringsStart, 0);
            stringOffsets[index] = checked(offset + stringsStart + relativeOffset);
        }

        return new StringPool(data, stringOffsets, (flags & 0x100) != 0, offset + chunkSize);
    }

    private static void ReadManifestAttributes(
        byte[] data,
        int offset,
        int chunkHeaderSize,
        int chunkSize,
        StringPool stringPool,
        ref string? packageName,
        ref string? versionName,
        ref long? versionCode)
    {
        if (chunkHeaderSize < 16) return;
        var extension = checked(offset + chunkHeaderSize);
        if (extension + 20 > offset + chunkSize) return;

        var nameIndex = ReadUInt32(data, extension + 4);
        if (!string.Equals(stringPool.Get(nameIndex), "manifest", StringComparison.Ordinal)) return;

        var attributeStart = ReadUInt16(data, extension + 8);
        var attributeSize = ReadUInt16(data, extension + 10);
        var attributeCount = ReadUInt16(data, extension + 12);
        if (attributeSize < 20) return;

        var attributes = checked(extension + attributeStart);
        var attributesEnd = checked(attributes + attributeCount * attributeSize);
        if (attributes < extension || attributesEnd > offset + chunkSize) return;

        for (var index = 0; index < attributeCount; index++)
        {
            var attribute = checked(attributes + index * attributeSize);
            var attributeName = stringPool.Get(ReadUInt32(data, attribute + 4));
            var rawValueIndex = ReadUInt32(data, attribute + 8);
            var valueType = data[attribute + 15];
            var valueData = ReadUInt32(data, attribute + 16);
            var value = rawValueIndex != NoIndex
                ? stringPool.Get(rawValueIndex)
                : valueType == TypedString ? stringPool.Get(valueData) : null;

            switch (attributeName)
            {
                case "package":
                    packageName = value;
                    break;
                case "versionName":
                    versionName = value;
                    break;
                case "versionCode" when valueType is TypedIntDecimal or TypedIntHex:
                    versionCode = valueData;
                    break;
            }
        }
    }

    private static int CheckedCount(uint value) => value <= int.MaxValue / 4 ? (int)value : throw new InvalidDataException("String pool AXML grande demais.");

    private static int CheckedSize(uint value, int limit, int offset)
    {
        if (value > int.MaxValue || value > limit - offset) throw new InvalidDataException($"Tamanho AXML inválido em 0x{offset:X}.");
        return (int)value;
    }

    private static ushort ReadUInt16(byte[] data, int offset)
    {
        if (offset < 0 || offset + 2 > data.Length) throw new InvalidDataException($"Leitura AXML fora dos limites em 0x{offset:X}.");
        return (ushort)(data[offset] | data[offset + 1] << 8);
    }

    private static uint ReadUInt32(byte[] data, int offset)
    {
        if (offset < 0 || offset + 4 > data.Length) throw new InvalidDataException($"Leitura AXML fora dos limites em 0x{offset:X}.");
        return (uint)(data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16 | data[offset + 3] << 24);
    }

    private sealed class StringPool
    {
        private readonly byte[] _data;
        private readonly int[] _offsets;
        private readonly bool _utf8;
        private readonly int _end;

        public StringPool(byte[] data, int[] offsets, bool utf8, int end)
        {
            _data = data;
            _offsets = offsets;
            _utf8 = utf8;
            _end = end;
        }

        public string? Get(uint index)
        {
            if (index == NoIndex || index >= _offsets.Length) return null;
            var offset = _offsets[index];
            return _utf8 ? ReadUtf8(offset) : ReadUtf16(offset);
        }

        private string ReadUtf8(int offset)
        {
            var cursor = offset;
            _ = ReadLength8(ref cursor);
            var byteLength = ReadLength8(ref cursor);
            if (byteLength < 0 || cursor > _end - byteLength) throw new InvalidDataException("String UTF-8 AXML fora dos limites.");
            return Encoding.UTF8.GetString(_data, cursor, byteLength);
        }

        private string ReadUtf16(int offset)
        {
            var cursor = offset;
            var characterLength = ReadLength16(ref cursor);
            var byteLength = checked(characterLength * 2);
            if (cursor > _end - byteLength) throw new InvalidDataException("String UTF-16 AXML fora dos limites.");
            return Encoding.Unicode.GetString(_data, cursor, byteLength);
        }

        private int ReadLength8(ref int offset)
        {
            var first = ReadByte(ref offset);
            if ((first & 0x80) == 0) return first;
            return checked(((first & 0x7F) << 8) | ReadByte(ref offset));
        }

        private int ReadLength16(ref int offset)
        {
            var first = ReadUInt16(_data, offset);
            offset = checked(offset + 2);
            if ((first & 0x8000) == 0) return first;
            var second = ReadUInt16(_data, offset);
            offset = checked(offset + 2);
            return checked(((first & 0x7FFF) << 16) | second);
        }

        private byte ReadByte(ref int offset)
        {
            if (offset < 0 || offset >= _end) throw new InvalidDataException("String AXML fora dos limites.");
            return _data[offset++];
        }
    }
}
