using PetRunner.Core;
using SkiaSharp;

namespace PetRunner.Tests;

internal static class SpriteAtlasTests
{
    public static void Run()
    {
        var path = Path.Combine(Path.GetTempPath(), $"PetRunnerAtlas-{Guid.NewGuid():N}.png");
        try
        {
            using (var source = new SKBitmap(1536, 1872))
            {
                source.SetPixel(4, 4, SKColors.Red);
                source.SetPixel(4, 208 + 4, SKColors.Blue);
                using var image = SKImage.FromBitmap(source);
                using var data = image.Encode(SKEncodedImageFormat.Png, 100);
                using var stream = File.Create(path);
                data.SaveTo(stream);
            }

            using var atlas = SpriteAtlas.Load(path, SpriteVersion.V1);
            using var first = SKBitmap.Decode(atlas.FramePng(new AtlasAddress(0, 0)));
            using var second = SKBitmap.Decode(atlas.FramePng(new AtlasAddress(1, 0)));
            Check.Equal(SKColors.Red, first.GetPixel(4, 4));
            Check.Equal(SKColors.Blue, second.GetPixel(4, 4));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
