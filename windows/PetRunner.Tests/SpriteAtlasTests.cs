using PetRunner.Core;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;

namespace PetRunner.Tests;

internal static class SpriteAtlasTests
{
    public static void Run()
    {
        var path = Path.Combine(Path.GetTempPath(), $"PetRunnerAtlas-{Guid.NewGuid():N}.png");
        try
        {
            using (var source = new Image<Rgba32>(1536, 1872))
            {
                source[4, 4] = new Rgba32(255, 0, 0, 255);
                source[4, 208 + 4] = new Rgba32(0, 0, 255, 255);
                source.SaveAsPng(path);
            }

            using var atlas = SpriteAtlas.Load(path, SpriteVersion.V1);
            using var first = Image.Load<Rgba32>(atlas.FramePng(new AtlasAddress(0, 0)));
            using var second = Image.Load<Rgba32>(atlas.FramePng(new AtlasAddress(1, 0)));
            Check.Equal(new Rgba32(255, 0, 0, 255), first[4, 4]);
            Check.Equal(new Rgba32(0, 0, 255, 255), second[4, 4]);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
