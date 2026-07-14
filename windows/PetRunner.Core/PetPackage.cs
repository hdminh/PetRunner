using System.Text.Json;

namespace PetRunner.Core;

public static class PetPackageLoader
{
    public static PetScanResult LoadDirectory(string petsPath)
    {
        RustNative.Require(RustNative.ScanPets(petsPath, out var data));
        var result = JsonSerializer.Deserialize<RustPetScan>(RustNative.TakeBuffer(data), JsonOptions)
            ?? throw new InvalidDataException("Rust returned an invalid pet scan result");
        return new PetScanResult(
            result.Valid.Select(pet => new PetDescriptor(pet.Id, pet.DisplayName, pet.Description, (SpriteVersion)pet.Version, pet.PackagePath, pet.SpritesheetPath)).ToArray(),
            result.Invalid);
    }

    public static PetDescriptor LoadPackage(string directory)
    {
        var result = LoadDirectory(Path.GetDirectoryName(Path.GetFullPath(directory))!);
        return result.Pets.FirstOrDefault(pet => Path.GetFullPath(pet.PackagePath) == Path.GetFullPath(directory))
            ?? throw new InvalidDataException(result.Failures.FirstOrDefault(failure => failure.Id == Path.GetFileName(directory))?.Message ?? "package could not be loaded");
    }

    private sealed record RustPetScan(IReadOnlyList<RustPetDescriptor> Valid, IReadOnlyList<PetFailure> Invalid);
    private sealed record RustPetDescriptor(string Id, string DisplayName, string? Description, int Version, string PackagePath, string SpritesheetPath);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
}
