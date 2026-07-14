using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace PetRunner.Core;

public sealed class SpriteAtlas : IDisposable
{
    public const int CellWidth = 192;
    public const int CellHeight = 208;
    private readonly Image<Rgba32> image;
    private readonly Dictionary<AtlasAddress, byte[]> cache = [];

    private SpriteAtlas(Image<Rgba32> image, SpriteVersion version)
    {
        this.image = image;
        Version = version;
    }

    public SpriteVersion Version { get; }

    public static SpriteAtlas Load(string path, SpriteVersion version)
    {
        var image = Image.Load<Rgba32>(path);
        var expected = version.ExpectedSize();
        if (image.Width != expected.Width || image.Height != expected.Height)
        {
            image.Dispose();
            throw new InvalidDataException("atlas dimensions do not match sprite version");
        }
        return new SpriteAtlas(image, version);
    }

    public byte[] FramePng(AtlasAddress address)
    {
        if (address.Column is < 0 or >= 8 || address.Row < 0 || address.Row >= Version.RowCount())
            throw new ArgumentOutOfRangeException(nameof(address));
        if (cache.TryGetValue(address, out var cached)) return cached;

        using var frame = image.Clone(context => context.Crop(
            new Rectangle(address.Column * CellWidth, address.Row * CellHeight, CellWidth, CellHeight)));
        using var stream = new MemoryStream();
        frame.SaveAsPng(stream);
        var encoded = stream.ToArray();
        cache[address] = encoded;
        return encoded;
    }

    public void Dispose() => image.Dispose();
}
