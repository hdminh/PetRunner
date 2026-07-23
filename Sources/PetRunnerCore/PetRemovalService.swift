import Foundation

public enum PetRemovalError: Error, LocalizedError, Equatable {
    case notFound(String)
    case escapesPetsDirectory
    case invalidPetID

    public var errorDescription: String? {
        switch self {
        case let .notFound(id): "No installed pet matches id \(id)."
        case .escapesPetsDirectory: "Refusing to delete a path outside the pets directory."
        case .invalidPetID: "Pet id is invalid."
        }
    }
}

/// Removes an installed pet package from the configured pets directory.
///
/// Deletes only the directory entry under `petsDirectory` (symlink entries remove
/// the link, not an external target). Never follows package paths that escape the
/// pets folder.
public final class PetRemovalService {
    private let fileManager: FileManager
    private let loader: PetPackageLoader

    public init(fileManager: FileManager = .default, loader: PetPackageLoader = .init()) {
        self.fileManager = fileManager
        self.loader = loader
    }

    @discardableResult
    public func remove(id: String, from petsDirectory: URL) throws -> URL {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != "." && trimmed != ".." else {
            throw PetRemovalError.invalidPetID
        }

        let root = petsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: petsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw PetRemovalError.notFound(trimmed)
        }

        for entry in entries {
            guard let pet = try? loader.loadPackage(at: entry), pet.id == trimmed else { continue }
            let deletionURL = try validatedDeletionURL(entry, petsRoot: root)
            try fileManager.removeItem(at: deletionURL)
            return deletionURL
        }
        throw PetRemovalError.notFound(trimmed)
    }

    /// Ensures `entry` is a direct child of the pets directory and safe to delete.
    /// Returns the on-disk entry URL to remove (never a resolved external target).
    private func validatedDeletionURL(_ entry: URL, petsRoot: URL) throws -> URL {
        let standardized = entry.standardizedFileURL
        guard !standardized.pathComponents.contains("..") else {
            throw PetRemovalError.escapesPetsDirectory
        }

        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == petsRoot.path else {
            throw PetRemovalError.escapesPetsDirectory
        }

        // If the entry itself is a symlink, delete only the link inside pets/.
        // If it is a real directory, require that resolving it still stays inside pets/.
        let isSymlink = (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if !isSymlink {
            let resolved = standardized.resolvingSymlinksInPath()
            guard isContained(resolved, by: petsRoot) else {
                throw PetRemovalError.escapesPetsDirectory
            }
        }

        return standardized
    }

    private func isContained(_ candidate: URL, by directory: URL) -> Bool {
        let parent = directory.pathComponents
        let child = candidate.pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }
}
