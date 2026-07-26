import Foundation

/// Built-in default pet shipped with PetRunner and preferred on first launch.
public enum DefaultPet {
    public static let id = "maomao"
    public static let downloadPetsURL = URL(string: "https://pet-runner.com")!
    public static let bundleRootRelativePath = "DefaultPets"
    public static let bundleRelativePath = "DefaultPets/maomao"
}

public enum PetSelectionOrdering {
    /// Prefer an explicitly selected pet, then the built-in default id, then scan order.
    public static func orderedCandidates(from pets: [PetDescriptor], selectedID: String?) -> [PetDescriptor] {
        guard !pets.isEmpty else { return [] }
        let preferred =
            pets.first { $0.id == selectedID }
            ?? pets.first { $0.id == DefaultPet.id }
            ?? pets[0]
        return [preferred] + pets.filter { $0.id != preferred.id }
    }
}

public enum DefaultPetInstallError: Error, Equatable {
    case unsafePetID(String)
    case destinationEscapesPetsDirectory
}

public struct DefaultPetInstaller {
    private let fileManager: FileManager
    private let loader: PetPackageLoader

    public init(fileManager: FileManager = .default, loader: PetPackageLoader = .init()) {
        self.fileManager = fileManager
        self.loader = loader
    }

    /// Installs every valid pet package under `bundledRoot` that is missing from the library.
    /// Never overwrites an existing package. Invalid folders are skipped.
    @discardableResult
    public func installAllMissing(bundledRoot: URL, into petsDirectory: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }
        let packages = try fileManager.contentsOfDirectory(
            at: bundledRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var installed = 0
        for package in packages {
            do {
                if try installIfMissing(bundledPackage: package, into: petsDirectory) {
                    installed += 1
                }
            } catch {
                // Skip invalid bundled folders so one bad package does not block the rest.
            }
        }
        return installed
    }

    /// Copies a bundled pet package into the library when missing. Never overwrites an existing package.
    /// Destination folder uses the package id from pet.json.
    @discardableResult
    public func installIfMissing(bundledPackage: URL, into petsDirectory: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledPackage.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let pet = try loader.loadPackage(at: bundledPackage)
        let id = try Self.requireSafePetID(pet.id)
        let petsRoot = petsDirectory.standardizedFileURL
        let destination = petsRoot.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        try Self.ensureDestinationInsidePetsRoot(destination, petsRoot: petsRoot)
        if fileManager.fileExists(atPath: destination.path) { return false }

        try fileManager.createDirectory(at: petsRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundledPackage, to: destination)
        _ = try loader.loadPackage(at: destination)
        return true
    }

    static func requireSafePetID(_ id: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed == "."
            || trimmed == ".."
            || trimmed.contains("/")
            || trimmed.contains("\\")
            || (trimmed as NSString).isAbsolutePath
        {
            throw DefaultPetInstallError.unsafePetID(id)
        }
        return trimmed
    }

    private static func ensureDestinationInsidePetsRoot(_ destination: URL, petsRoot: URL) throws {
        let rootPath = petsRoot.path
        let destinationPath = destination.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard destinationPath == rootPath || destinationPath.hasPrefix(prefix) else {
            throw DefaultPetInstallError.destinationEscapesPetsDirectory
        }
    }
}
