namespace PetRunner.Core;

public static class DefaultPet
{
    public const string Id = "maomao";
    public const string DownloadPetsUrl = "https://pet-runner.com";
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
    public bool InstallIfMissing(string bundledPackage, string petsDirectory)
    {
        var destination = Path.Combine(petsDirectory, DefaultPet.Id);
        if (Directory.Exists(destination)) return false;
        if (!Directory.Exists(bundledPackage)) return false;

        _ = PetPackageLoader.LoadPackage(bundledPackage);
        Directory.CreateDirectory(petsDirectory);
        CopyDirectory(bundledPackage, destination);
        _ = PetPackageLoader.LoadPackage(destination);
        return true;
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
