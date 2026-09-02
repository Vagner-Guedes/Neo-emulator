using System.Formats.Asn1;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record ApkSignatureValidationResult(
    bool Valid,
    string? CertificateSha256,
    string ExpectedSha256,
    string Detail);

public static class ApkSignatureService
{
    private const string SignedDataObjectIdentifier = "1.2.840.113549.1.7.2";

    public static ApkSignatureValidationResult Validate(string apkPath, string expectedSha256)
    {
        var expected = Normalize(expectedSha256);
        var actual = ReadCertificateSha256(apkPath);
        var valid = !string.IsNullOrWhiteSpace(actual) &&
                    !string.IsNullOrWhiteSpace(expected) &&
                    string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
        var detail = actual is null
            ? "Nenhum certificado X.509 foi encontrado na assinatura v1 do APK."
            : valid
                ? "Fingerprint SHA-256 do certificado corresponde ao esperado."
                : $"Fingerprint SHA-256 divergente: encontrado={actual}; esperado={expected}.";
        return new ApkSignatureValidationResult(valid, actual, expected, detail);
    }

    public static string? ReadCertificateSha256(string apkPath)
    {
        using var archive = ZipFile.OpenRead(apkPath);
        var signatureEntry = archive.Entries.FirstOrDefault(entry =>
            entry.FullName.StartsWith("META-INF/", StringComparison.OrdinalIgnoreCase) &&
            (entry.FullName.EndsWith(".RSA", StringComparison.OrdinalIgnoreCase) ||
             entry.FullName.EndsWith(".DSA", StringComparison.OrdinalIgnoreCase) ||
             entry.FullName.EndsWith(".EC", StringComparison.OrdinalIgnoreCase)));
        if (signatureEntry is null) return null;

        using var stream = signatureEntry.Open();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return ReadPkcs7CertificateSha256(memory.ToArray());
    }

    private static string? ReadPkcs7CertificateSha256(byte[] encoded)
    {
        try
        {
            var contentInfoReader = new AsnReader(encoded, AsnEncodingRules.BER);
            var contentInfo = contentInfoReader.ReadSequence();
            var contentType = contentInfo.ReadObjectIdentifier();
            if (!string.Equals(contentType, SignedDataObjectIdentifier, StringComparison.Ordinal)) return null;

            var explicitContent = contentInfo.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0));
            var signedData = explicitContent.ReadSequence();
            _ = signedData.ReadInteger();
            Drain(signedData.ReadSetOf());
            var encapsulatedContentInfo = signedData.ReadSequence();
            _ = encapsulatedContentInfo.ReadObjectIdentifier();
            if (encapsulatedContentInfo.HasData) _ = encapsulatedContentInfo.ReadEncodedValue();

            if (!signedData.HasData) return null;
            var certificates = signedData.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0));
            while (certificates.HasData)
            {
                var certificateEncoding = certificates.ReadEncodedValue();
                try
                {
                    using var certificate = new X509Certificate2(certificateEncoding.ToArray());
                    return Convert.ToHexString(SHA256.HashData(certificate.RawData));
                }
                catch (CryptographicException)
                {
                    // CertificateSet may contain a choice other than an X.509 certificate.
                }
            }
        }
        catch (AsnContentException)
        {
            return null;
        }
        catch (CryptographicException)
        {
            return null;
        }

        return null;
    }

    private static void Drain(AsnReader reader)
    {
        while (reader.HasData) _ = reader.ReadEncodedValue();
    }

    private static string Normalize(string value) =>
        new string((value ?? string.Empty).Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();
}
