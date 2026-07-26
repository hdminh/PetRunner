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

            var bundledRoot = Path.Combine(root, "DefaultPets");
            var misty = Path.Combine(bundledRoot, "misty");
            var broken = Path.Combine(bundledRoot, "broken");
            Directory.CreateDirectory(misty);
            Directory.CreateDirectory(broken);
            WritePet(misty, "misty");
            File.WriteAllText(Path.Combine(broken, "pet.json"), "{\"id\":\"broken\"}");
            var multiPets = Path.Combine(root, "multi-pets");
            Check.Equal(1, installer.InstallAllMissing(bundledRoot, multiPets));
            Check.True(File.Exists(Path.Combine(multiPets, "misty", "pet.json")), "misty should install from DefaultPets root");
            Check.True(!Directory.Exists(Path.Combine(multiPets, "broken")), "invalid package should be skipped");
            Check.Equal(0, installer.InstallAllMissing(bundledRoot, multiPets));

            var escapeCaught = false;
            try
            {
                var escapePkg = Path.Combine(root, "escape-pkg");
                Directory.CreateDirectory(escapePkg);
                WritePet(escapePkg, "../escape");
                installer.InstallIfMissing(escapePkg, multiPets);
            }
            catch (InvalidDataException)
            {
                escapeCaught = true;
            }
            Check.True(escapeCaught, "relative escape id must be rejected");
            Check.True(!Directory.Exists(Path.GetFullPath(Path.Combine(multiPets, "..", "escape"))), "escape id must not create files outside pets dir");

            var rootedCaught = false;
            try
            {
                var rootedPkg = Path.Combine(root, "rooted-pkg");
                Directory.CreateDirectory(rootedPkg);
                WritePetWithRawId(rootedPkg, @"C:\petrunner-install-escape-test");
                installer.InstallIfMissing(rootedPkg, multiPets);
            }
            catch (InvalidDataException)
            {
                rootedCaught = true;
            }
            Check.True(rootedCaught, "rooted pet id must be rejected");
            Check.True(!Directory.Exists(@"C:\petrunner-install-escape-test"), "rooted id must not create an outside folder");

            Check.True(
                string.Equals("safe-pet", DefaultPetInstaller.RequireSafePetId("  safe-pet  "), StringComparison.Ordinal),
                "valid ids should trim and pass");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void WritePet(string directory, string id)
    {
        WritePetWithRawId(directory, id);
    }

    private static void WritePetWithRawId(string directory, string id)
    {
        var escaped = id.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal);
        File.WriteAllText(
            Path.Combine(directory, "pet.json"),
            $"{{\"id\":\"{escaped}\",\"displayName\":\"pet\",\"spritesheetPath\":\"spritesheet.webp\"}}");
        using var bitmap = new SKBitmap(1536, 1872);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        using var stream = File.Create(Path.Combine(directory, "spritesheet.webp"));
        data.SaveTo(stream);
    }

    private static PetDescriptor FakePet(string id) =>
        new(id, id, null, SpriteVersion.V1, Path.Combine("/tmp", id), Path.Combine("/tmp", id, "spritesheet.webp"));
}
