using System.IO.Compression;
using PetRunner.Core;
using SkiaSharp;

namespace PetRunner.Tests;

internal static class PetImportTests
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"PetRunnerImportTests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var pets = Path.Combine(root, "pets");
            var backups = Path.Combine(root, "backups");
            var flatDir = Path.Combine(root, "flat");
            Directory.CreateDirectory(flatDir);
            WritePet(flatDir, "maomao");
            var flatZip = Path.Combine(root, "maomao.zip");
            ZipFile.CreateFromDirectory(flatDir, flatZip, CompressionLevel.NoCompression, includeBaseDirectory: false);

            var imported = new PetImportService().Import(flatZip, pets, backups);
            Check.Equal("maomao", imported.Id);
            Check.True(File.Exists(Path.Combine(pets, "maomao", "pet.json")), "flat zip should install under maomao/");

            var nestedRoot = Path.Combine(root, "nested-src");
            var package = Path.Combine(nestedRoot, "sample-pet");
            var junk = Path.Combine(nestedRoot, "__MACOSX");
            Directory.CreateDirectory(package);
            Directory.CreateDirectory(junk);
            WritePet(package, "sample-pet");
            File.WriteAllBytes(Path.Combine(junk, "._junk"), [0]);
            var nestedZip = Path.Combine(root, "nested.zip");
            ZipFile.CreateFromDirectory(nestedRoot, nestedZip, CompressionLevel.NoCompression, includeBaseDirectory: false);
            var nestedImported = new PetImportService().Import(nestedZip, pets, backups);
            Check.Equal("sample-pet", nestedImported.Id);

            var ordered = PetSelectionOrdering.OrderedCandidates(
                [
                    FakePet("aladin"),
                    FakePet("maomao"),
                    FakePet("zebra"),
                ],
                selectedId: null);
            Check.Equal("maomao", ordered[0].Id);

            var bundled = Path.Combine(root, "bundled", "maomao");
            Directory.CreateDirectory(bundled);
            WritePet(bundled, "maomao");
            var seedPets = Path.Combine(root, "seed-pets");
            var installer = new DefaultPetInstaller();
            Check.True(installer.InstallIfMissing(bundled, seedPets), "first seed should copy");
            Check.True(!installer.InstallIfMissing(bundled, seedPets), "second seed should no-op");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void WritePet(string directory, string id)
    {
        File.WriteAllText(
            Path.Combine(directory, "pet.json"),
            $"{{\"id\":\"{id}\",\"displayName\":\"{id}\",\"spritesheetPath\":\"spritesheet.webp\"}}");
        using var bitmap = new SKBitmap(1536, 1872);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        using var stream = File.Create(Path.Combine(directory, "spritesheet.webp"));
        data.SaveTo(stream);
    }

    private static PetDescriptor FakePet(string id) =>
        new(id, id, null, SpriteVersion.V1, Path.Combine("/tmp", id), Path.Combine("/tmp", id, "spritesheet.webp"));
}
