import Foundation

/// Built-in default pet shipped with PetRunner and preferred on first launch.
public enum DefaultPet {
    public static let id = "maomao"
    public static let downloadPetsURL = URL(string: "https://pet-runner.com")!
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

public struct DefaultPetInstaller {
    private let fileManager: FileManager
    private let loader: PetPackageLoader

    public init(fileManager: FileManager = .default, loader: PetPackageLoader = .init()) {
        self.fileManager = fileManager
        self.loader = loader
    }

    /// Copies the bundled default pet into the library when missing. Never overwrites an existing package.
    @discardableResult
    public func installIfMissing(bundledPackage: URL, into petsDirectory: URL) throws -> Bool {
        let destination = petsDirectory.appendingPathComponent(DefaultPet.id, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledPackage.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        _ = try loader.loadPackage(at: bundledPackage)
        try fileManager.createDirectory(at: petsDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundledPackage, to: destination)
        _ = try loader.loadPackage(at: destination)
        return true
    }
}
