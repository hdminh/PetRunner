using System.IO.Compression;
using System.Text.Json;

namespace PetRunner.Core;

public sealed class DuplicatePetException(string id) : IOException($"A pet with id {id} already exists.")
{
    public string PetId { get; } = id;
}

public sealed class PetImportService
{
    public PetDescriptor Import(string source, string petsDirectory, string backupDirectory, bool replaceExisting = false)
    {
        var sourcePath = Path.GetFullPath(source);
        if (Directory.Exists(sourcePath))
            return ImportDirectory(sourcePath, petsDirectory, backupDirectory, replaceExisting);
        if (File.Exists(sourcePath) && sourcePath.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            return ImportZip(sourcePath, petsDirectory, backupDirectory, replaceExisting);
        throw new InvalidDataException("Choose a pet package folder or ZIP archive.");
    }

    public PetDescriptor ImportDirectory(string source, string petsDirectory, string backupDirectory, bool replaceExisting = false)
    {
        var sourcePath = Path.GetFullPath(source);
        if (!Directory.Exists(sourcePath)) throw new InvalidDataException("Choose a pet package folder.");
        var sourceName = new DirectoryInfo(sourcePath).Name;
        if (string.IsNullOrWhiteSpace(sourceName)) throw new InvalidDataException("Choose a pet package folder.");
        if ((File.GetAttributes(sourcePath) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("The import folder cannot be a link.");
        RejectLinks(sourcePath);
        var sourcePet = PetPackageLoader.LoadPackage(sourcePath);

        Directory.CreateDirectory(petsDirectory);
        var existing = PetPackageLoader.LoadDirectory(petsDirectory).Pets
            .FirstOrDefault(pet => string.Equals(pet.Id, sourcePet.Id, StringComparison.OrdinalIgnoreCase));
        if (existing is not null && !replaceExisting) throw new DuplicatePetException(sourcePet.Id);

        var stagingRoot = Path.Combine(Path.GetTempPath(), "PetRunnerImport", Guid.NewGuid().ToString("N"));
        var staged = Path.Combine(stagingRoot, sourceName);
        Directory.CreateDirectory(stagingRoot);
        try
        {
            CopyDirectory(sourcePath, staged);
            _ = PetPackageLoader.LoadPackage(staged);
            var destination = existing?.PackagePath ?? Path.Combine(Path.GetFullPath(petsDirectory), sourceName);
            if (existing is null && Directory.Exists(destination))
                throw new IOException($"A package folder named {Path.GetFileName(destination)} already exists.");
            string? backup = null;
            var originalRemoved = false;
            try
            {
                if (Directory.Exists(destination))
                {
                    Directory.CreateDirectory(backupDirectory);
                    backup = Path.Combine(backupDirectory, $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{Guid.NewGuid():N}-{Path.GetFileName(destination)}");
                    CopyDirectory(destination, backup);
                    _ = PetPackageLoader.LoadPackage(backup);
                    originalRemoved = true;
                    Directory.Delete(destination, recursive: true);
                }
                CopyDirectory(staged, destination);
                var imported = PetPackageLoader.LoadPackage(destination);
                TrimBackups(backupDirectory);
                return imported;
            }
            catch
            {
                try
                {
                    if ((originalRemoved || backup is null) && Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
                }
                catch { }
                try
                {
                    if (originalRemoved && backup is not null && Directory.Exists(backup) && !Directory.Exists(destination))
                        CopyDirectory(backup, destination);
                }
                catch { }
                throw;
            }
        }
        finally
        {
            try { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true); } catch { }
        }
    }

    public PetDescriptor ImportZip(string archive, string petsDirectory, string backupDirectory, bool replaceExisting = false)
    {
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PetRunnerImport", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stagingRoot);
        try
        {
            using (var zip = ZipFile.OpenRead(archive))
            {
                var entries = zip.Entries.Where(entry => !string.IsNullOrEmpty(entry.FullName)).ToList();
                var counted = entries.Count(entry => !IsJunkArchiveEntry(entry.FullName));
                if (counted > 128) throw new InvalidDataException("The ZIP is larger than the import safety limit.");
                foreach (var entry in entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    if (name.StartsWith('/') || name.Split('/').Contains(".."))
                        throw new InvalidDataException($"The ZIP contains an unsafe entry: {entry.FullName}");
                }
            }
            ZipFile.ExtractToDirectory(archive, stagingRoot);
            var package = ResolvePackageRoot(stagingRoot);
            return ImportDirectory(package, petsDirectory, backupDirectory, replaceExisting);
        }
        finally
        {
            try { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true); } catch { }
        }
    }

    internal static string ResolvePackageRoot(string staging)
    {
        var contents = Directory.EnumerateFileSystemEntries(staging)
            .Where(path => !IsJunkName(Path.GetFileName(path)))
            .ToList();
        var directories = contents.Where(Directory.Exists).ToList();
        var files = contents.Where(File.Exists).ToList();

        if (directories.Count == 1 && files.Count == 0)
            return directories[0];

        if (files.Any(path => string.Equals(Path.GetFileName(path), "pet.json", StringComparison.OrdinalIgnoreCase)))
            return WrapFlatPackage(staging, contents);

        var candidates = directories
            .Where(path => File.Exists(Path.Combine(path, "pet.json")))
            .ToList();
        if (candidates.Count == 1)
            return candidates[0];

        throw new InvalidDataException("The import must contain exactly one pet package.");
    }

    private static string WrapFlatPackage(string staging, IReadOnlyList<string> items)
    {
        var manifestPath = Path.Combine(staging, "pet.json");
        var folderName = PackageFolderName(manifestPath);
        var package = Path.Combine(staging, folderName);
        Directory.CreateDirectory(package);
        foreach (var item in items)
        {
            var name = Path.GetFileName(item);
            if (string.Equals(name, folderName, StringComparison.Ordinal)) continue;
            var destination = Path.Combine(package, name);
            if (Directory.Exists(destination) || File.Exists(destination))
                throw new InvalidDataException("The import must contain exactly one pet package.");
            if (Directory.Exists(item)) Directory.Move(item, destination);
            else File.Move(item, destination);
        }
        return package;
    }

    private static string PackageFolderName(string manifestPath)
    {
        try
        {
            using var stream = File.OpenRead(manifestPath);
            using var document = JsonDocument.Parse(stream);
            if (document.RootElement.TryGetProperty("id", out var idProperty)
                && idProperty.ValueKind == JsonValueKind.String)
            {
                var id = idProperty.GetString()?.Trim();
                if (!string.IsNullOrEmpty(id)
                    && !id.Contains('/')
                    && !id.Contains('\\')
                    && id is not ("." or ".."))
                {
                    return id;
                }
            }
        }
        catch { }
        return "imported-pet";
    }

    private static void RejectLinks(string root)
    {
        foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException($"The import contains a link: {Path.GetFileName(path)}");
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source)) File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (var directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }

    private static void TrimBackups(string root)
    {
        if (!Directory.Exists(root)) return;
        foreach (var stale in Directory.EnumerateDirectories(root).OrderByDescending(Path.GetFileName, StringComparer.Ordinal).Skip(3))
        {
            try { Directory.Delete(stale, recursive: true); } catch { }
        }
    }

    internal static bool IsJunkName(string name) =>
        name is "__MACOSX" or ".DS_Store" || name.StartsWith("._", StringComparison.Ordinal);

    internal static bool IsJunkArchiveEntry(string entry)
    {
        var normalized = entry.Replace('\\', '/');
        var parts = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Contains("__MACOSX", StringComparer.Ordinal)
            || parts.Any(part => part.StartsWith("._", StringComparison.Ordinal))
            || normalized.EndsWith(".DS_Store", StringComparison.Ordinal);
    }
}
