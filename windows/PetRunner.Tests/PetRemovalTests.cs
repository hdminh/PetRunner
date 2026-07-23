using PetRunner.Core;
using SkiaSharp;

namespace PetRunner.Tests;

internal static class PetRemovalTests
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"PetRunnerRemove-{Guid.NewGuid():N}");
        var pets = Path.Combine(root, "pets");
        Directory.CreateDirectory(pets);
        try
        {
            CreatePet(pets, "misty", "{\"id\":\"misty\"}", 1536, 1872);
            var removed = PetRemovalService.Remove("misty", pets);
            Check.Equal(Path.Combine(pets, "misty"), removed);
            Check.True(!Directory.Exists(removed), "Package directory should be gone");

            try
            {
                PetRemovalService.Remove("../escape", pets);
                throw new InvalidOperationException("Expected invalid pet id");
            }
            catch (PetRemovalException error)
            {
                Check.Equal("invalid_pet", error.Code);
            }
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void CreatePet(string root, string name, string manifest, int width, int height)
    {
        var directory = Path.Combine(root, name);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "pet.json"), manifest);
        using var bitmap = new SKBitmap(width, height);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        using var stream = File.Create(Path.Combine(directory, "spritesheet.webp"));
        data.SaveTo(stream);
    }
}
