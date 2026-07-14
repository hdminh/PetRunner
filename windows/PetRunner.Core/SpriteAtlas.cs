using SkiaSharp;

namespace PetRunner.Core;

public sealed class SpriteAtlas : IDisposable
{
    public const int CellWidth = 192;
    public const int CellHeight = 208;
    private readonly SKBitmap image;
    private readonly Dictionary<AtlasAddress, byte[]> cache = [];

    private SpriteAtlas(SKBitmap image, SpriteVersion version)
    {
        this.image = image;
        Version = version;
    }

    public SpriteVersion Version { get; }

    public static SpriteAtlas Load(string path, SpriteVersion version)
    {
        var image = SKBitmap.Decode(path) ?? throw new InvalidDataException("atlas cannot be decoded");
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

        using var frame = new SKBitmap(CellWidth, CellHeight, SKColorType.Rgba8888, SKAlphaType.Premul);
        using (var canvas = new SKCanvas(frame))
        {
            var source = new SKRectI(
                address.Column * CellWidth,
                address.Row * CellHeight,
                (address.Column + 1) * CellWidth,
                (address.Row + 1) * CellHeight);
            canvas.DrawBitmap(image, source, new SKRect(0, 0, CellWidth, CellHeight));
        }
        using var snapshot = SKImage.FromBitmap(frame);
        using var data = snapshot.Encode(SKEncodedImageFormat.Png, 100);
        var encoded = data.ToArray();
        cache[address] = encoded;
        return encoded;
    }

    public void Dispose() => image.Dispose();
}
