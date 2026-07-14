using PetRunner.Core;
using System.Drawing;
using System.Drawing.Imaging;

namespace PetRunner.Tests;

internal static class SpriteAtlasTests
{
    public static void Run()
    {
        var path = Path.Combine(Path.GetTempPath(), $"PetRunnerAtlas-{Guid.NewGuid():N}.png");
        try
        {
            using (var source = new Bitmap(1536, 1872))
            {
                source.SetPixel(4, 4, Color.Red);
                source.SetPixel(4, 208 + 4, Color.Blue);
                source.Save(path, ImageFormat.Png);
            }

            using var atlas = SpriteAtlas.Load(path, SpriteVersion.V1);
            using var firstStream = new MemoryStream(atlas.FramePng(new AtlasAddress(0, 0)));
            using var secondStream = new MemoryStream(atlas.FramePng(new AtlasAddress(1, 0)));
            using var first = new Bitmap(firstStream);
            using var second = new Bitmap(secondStream);
            Check.Equal(Color.Red.ToArgb(), first.GetPixel(4, 4).ToArgb());
            Check.Equal(Color.Blue.ToArgb(), second.GetPixel(4, 4).ToArgb());
        }
        finally
        {
            File.Delete(path);
        }
    }
}
