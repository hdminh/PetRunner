namespace PetRunner.Core;

public static class DefaultPet
{
    public const string Id = "maomao";
    public const string DownloadPetsUrl = "https://pet-runner.com";
    public const string BundleRootRelativePath = "DefaultPets";
    public const string BundleRelativePath = "DefaultPets/maomao";
}

public static class PetSelectionOrdering
{
    public static IReadOnlyList<PetDescriptor> OrderedCandidates(IReadOnlyList<PetDescriptor> pets, string? selectedId)
    {
        if (pets.Count == 0) return pets;
        var preferred =
            pets.FirstOrDefault(pet => string.Equals(pet.Id, selectedId, StringComparison.Ordinal))
            ?? pets.FirstOrDefault(pet => string.Equals(pet.Id, DefaultPet.Id, StringComparison.Ordinal))
            ?? pets[0];
        return [preferred, .. pets.Where(pet => !string.Equals(pet.Id, preferred.Id, StringComparison.Ordinal))];
    }
}

public sealed class DefaultPetInstaller
{
    /// <summary>
    /// Installs every valid pet package under <paramref name="bundledRoot"/> that is missing
    /// from the library. Never overwrites an existing package. Invalid folders are skipped.
    /// </summary>
    public int InstallAllMissing(string bundledRoot, string petsDirectory)
    {
        if (!Directory.Exists(bundledRoot)) return 0;
        var installed = 0;
        foreach (var package in Directory.EnumerateDirectories(bundledRoot).OrderBy(path => path, StringComparer.Ordinal))
        {
            try
            {
                if (InstallIfMissing(package, petsDirectory)) installed++;
            }
            catch (Exception)
            {
                // Skip invalid bundled folders so one bad package does not block the rest.
            }
        }
        return installed;
    }

    /// <summary>
    /// Copies a bundled pet package into the library when missing. Never overwrites.
    /// Destination folder uses the package id from pet.json.
    /// </summary>
    public bool InstallIfMissing(string bundledPackage, string petsDirectory)
    {
        if (!Directory.Exists(bundledPackage)) return false;

        var pet = PetPackageLoader.LoadPackage(bundledPackage);
        var id = RequireSafePetId(pet.Id);
        var petsRoot = Path.GetFullPath(petsDirectory);
        var destination = Path.GetFullPath(Path.Combine(petsRoot, id));
        EnsureDestinationInsidePetsRoot(destination, petsRoot);
        if (Directory.Exists(destination)) return false;

        Directory.CreateDirectory(petsRoot);
        CopyDirectory(bundledPackage, destination);
        _ = PetPackageLoader.LoadPackage(destination);
        return true;
    }

    internal static string RequireSafePetId(string id)
    {
        var trimmed = id.Trim();
        if (trimmed.Length == 0
            || trimmed is "." or ".."
            || trimmed.Contains('/')
            || trimmed.Contains('\\')
            || Path.IsPathRooted(trimmed))
        {
            throw new InvalidDataException($"pet id {id} is not a safe library folder name");
        }
        return trimmed;
    }

    private static void EnsureDestinationInsidePetsRoot(string destination, string petsRoot)
    {
        var root = petsRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(destination, petsRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("pet install destination escapes the pets directory");
        }
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (var directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }
}
