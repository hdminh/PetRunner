using System.Text.Json;
using SixLabors.ImageSharp;

namespace PetRunner.Core;

public static class PetPackageLoader
{
    public static PetScanResult LoadDirectory(string petsPath)
    {
        if (!Directory.Exists(petsPath))
            return new PetScanResult([], [new PetFailure(Path.GetFileName(petsPath), "pets directory is missing")]);

        var pets = new List<PetDescriptor>();
        var failures = new List<PetFailure>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in Directory.EnumerateDirectories(petsPath).Order(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var pet = LoadPackage(directory);
                if (!seen.Add(pet.Id)) throw new InvalidDataException($"duplicate pet id {pet.Id}");
                pets.Add(pet);
            }
            catch (Exception error)
            {
                failures.Add(new PetFailure(Path.GetFileName(directory), error.Message));
            }
        }
        return new PetScanResult(pets, failures);
    }

    public static PetDescriptor LoadPackage(string directory)
    {
        var packagePath = Path.GetFullPath(directory);
        var manifestPath = Path.Combine(packagePath, "pet.json");
        if (!File.Exists(manifestPath)) throw new FileNotFoundException("pet.json is missing");

        Manifest manifest;
        try
        {
            manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath), JsonOptions)
                ?? throw new InvalidDataException("pet.json is empty");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException($"pet.json is invalid: {error.Message}", error);
        }

        var rawVersion = manifest.SpriteVersionNumber ?? 1;
        if (rawVersion is not (1 or 2))
            throw new InvalidDataException($"spriteVersionNumber {rawVersion} is unsupported");
        var version = (SpriteVersion)rawVersion;
        var relativeSheet = Nonempty(manifest.SpritesheetPath) ?? "spritesheet.webp";
        var sheetPath = Path.GetFullPath(Path.Combine(packagePath, relativeSheet));
        EnsureContained(sheetPath, packagePath);
        if (File.Exists(sheetPath))
        {
            var target = new FileInfo(sheetPath).ResolveLinkTarget(returnFinalTarget: true);
            if (target is not null) EnsureContained(target.FullName, packagePath);
        }

        var extension = Path.GetExtension(sheetPath).ToLowerInvariant();
        if (extension is not (".png" or ".webp"))
            throw new InvalidDataException($"spritesheet extension {extension} is unsupported");
        if (!File.Exists(sheetPath)) throw new FileNotFoundException("spritesheet file is missing");

        ImageInfo info;
        try
        {
            info = Image.Identify(sheetPath) ?? throw new InvalidDataException("spritesheet cannot be decoded");
        }
        catch (UnknownImageFormatException error)
        {
            throw new InvalidDataException("spritesheet cannot be decoded", error);
        }
        var expected = version.ExpectedSize();
        if (info.Width != expected.Width || info.Height != expected.Height)
            throw new InvalidDataException($"atlas is {info.Width}×{info.Height}; expected {expected.Width:0}×{expected.Height:0}");

        var fallback = Path.GetFileName(packagePath);
        var id = Nonempty(manifest.Id) ?? fallback;
        return new PetDescriptor(
            id,
            Nonempty(manifest.DisplayName) ?? id,
            Nonempty(manifest.Description),
            version,
            packagePath,
            sheetPath);
    }

    private static void EnsureContained(string candidate, string directory)
    {
        var relative = Path.GetRelativePath(directory, candidate);
        if (Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith($"..{Path.DirectorySeparatorChar}"))
            throw new InvalidDataException("spritesheetPath escapes the pet directory");
    }

    private static string? Nonempty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private sealed record Manifest(
        string? Id,
        string? DisplayName,
        string? Description,
        int? SpriteVersionNumber,
        string? SpritesheetPath);
}
