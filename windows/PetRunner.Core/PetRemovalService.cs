namespace PetRunner.Core;

public sealed class PetRemovalException : IOException
{
    public PetRemovalException(string code, string message) : base(message)
    {
        Code = code;
    }

    public string Code { get; }
}

public static class PetRemovalService
{
    public static string Remove(string id, string petsDirectory)
    {
        var trimmed = id.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.Contains('/') || trimmed.Contains('\\') || trimmed is "." or "..")
            throw new PetRemovalException("invalid_pet", "Pet id is invalid.");

        var root = Path.GetFullPath(petsDirectory);
        if (!Directory.Exists(root))
            throw new PetRemovalException("pet_not_found", $"No installed pet matches id {trimmed}.");

        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            string? petId;
            try { petId = PetPackageLoader.LoadPackage(entry).Id; }
            catch { continue; }
            if (!string.Equals(petId, trimmed, StringComparison.Ordinal)) continue;

            EnsureSafeDeletionTarget(entry, root);
            if (Directory.Exists(entry) || File.Exists(entry))
            {
                // Delete the pets-dir entry only. Symlink/junction entries remove the link,
                // not an external target.
                if ((File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
                    Directory.Delete(entry);
                else
                    Directory.Delete(entry, recursive: true);
            }
            return entry;
        }

        throw new PetRemovalException("pet_not_found", $"No installed pet matches id {trimmed}.");
    }

    private static void EnsureSafeDeletionTarget(string entry, string petsRoot)
    {
        var fullEntry = Path.GetFullPath(entry);
        var parent = Path.GetFullPath(Path.GetDirectoryName(fullEntry) ?? "");
        if (!string.Equals(parent, Path.GetFullPath(petsRoot), StringComparison.OrdinalIgnoreCase))
            throw new PetRemovalException("invalid_pet_path", "Refusing to delete a path outside the pets directory.");

        var attrs = File.GetAttributes(fullEntry);
        if ((attrs & FileAttributes.ReparsePoint) != 0) return;

        var relative = Path.GetRelativePath(petsRoot, fullEntry);
        if (Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            throw new PetRemovalException("invalid_pet_path", "Refusing to delete a path outside the pets directory.");
    }
}
