using PetRunner.Core;
using SkiaSharp;

namespace PetRunner.Tests;

internal static class PetLoaderTests
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"PetRunnerTests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            CreatePet(root, "default-pet", "{}", 1536, 1872);
            CreatePet(root, "v2-pet", "{\"spriteVersionNumber\":2}", 1536, 2288);
            CreatePet(root, "wrong-size", "{}", 100, 100);
            File.WriteAllText(Path.Combine(root, "outside.webp"), "not-an-image");
            CreateManifest(root, "escape", "{\"spritesheetPath\":\"../outside.webp\"}");

            var scan = PetPackageLoader.LoadDirectory(root);
            Check.Equal(2, scan.Pets.Count);
            Check.Equal("default-pet", scan.Pets[0].Id);
            Check.Equal(SpriteVersion.V1, scan.Pets[0].Version);
            Check.Equal(SpriteVersion.V2, scan.Pets[1].Version);
            Check.Equal(2, scan.Failures.Count);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void CreatePet(string root, string name, string manifest, int width, int height)
    {
        var directory = CreateManifest(root, name, manifest);
        using var bitmap = new SKBitmap(width, height);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        using var stream = File.Create(Path.Combine(directory, "spritesheet.webp"));
        data.SaveTo(stream);
    }

    private static string CreateManifest(string root, string name, string manifest)
    {
        var directory = Path.Combine(root, name);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "pet.json"), manifest);
        return directory;
    }
}
