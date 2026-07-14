namespace PetRunner.Core;

public enum SpriteVersion
{
    V1 = 1,
    V2 = 2,
}

public static class SpriteVersionExtensions
{
    public static int RowCount(this SpriteVersion version) => version == SpriteVersion.V1 ? 9 : 11;
    public static SizeD ExpectedSize(this SpriteVersion version) => new(1536, version.RowCount() * 208);
}

public readonly record struct AtlasAddress(int Row, int Column);
public readonly record struct SizeD(double Width, double Height);
public readonly record struct RectD(double X, double Y, double Width, double Height);

public sealed record PetDescriptor(
    string Id,
    string DisplayName,
    string? Description,
    SpriteVersion Version,
    string PackagePath,
    string SpritesheetPath);

public sealed record PetFailure(string Id, string Message);
public sealed record PetScanResult(IReadOnlyList<PetDescriptor> Pets, IReadOnlyList<PetFailure> Failures);
