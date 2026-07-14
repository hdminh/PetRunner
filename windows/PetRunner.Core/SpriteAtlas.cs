namespace PetRunner.Core;

public sealed class SpriteAtlas : IDisposable
{
    public const int CellWidth = 192;
    public const int CellHeight = 208;
    private IntPtr handle;

    private SpriteAtlas(IntPtr handle, SpriteVersion version) { this.handle = handle; Version = version; }
    public SpriteVersion Version { get; }

    public static SpriteAtlas Load(string path, SpriteVersion version)
    {
        RustNative.Require(RustNative.AtlasCreate(path, (int)version, out var handle));
        return new SpriteAtlas(handle, version);
    }

    public byte[] FramePng(AtlasAddress address)
    {
        RustNative.Require(RustNative.AtlasFramePng(handle, address.Row, address.Column, out var data));
        return RustNative.TakeBuffer(data);
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        RustNative.AtlasDestroy(handle);
        handle = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }
    ~SpriteAtlas() => Dispose();
}
