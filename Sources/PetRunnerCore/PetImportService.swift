import Foundation

public enum PetImportError: Error, LocalizedError {
    case unsupportedSource
    case unsafeArchiveEntry(String)
    case archiveTooLarge
    case invalidPackageRoot
    case duplicateRequiresReplacement(String)
    case unsafeLink(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: "Choose a pet folder or ZIP archive."
        case let .unsafeArchiveEntry(entry): "The ZIP contains an unsafe entry: \(entry)"
        case .archiveTooLarge: "The ZIP is larger than the import safety limit."
        case .invalidPackageRoot: "The import must contain exactly one pet package."
        case let .duplicateRequiresReplacement(id): "A pet with id \(id) already exists. Confirm replacement to continue."
        case let .unsafeLink(path): "The import contains a link, which is not allowed: \(path)"
        }
    }
}

public struct PetImportResult {
    public let pet: PetDescriptor
    public let replaced: Bool
}

public final class PetImportService {
    private let fileManager: FileManager
    private let loader: PetPackageLoader

    public init(fileManager: FileManager = .default, loader: PetPackageLoader = .init()) {
        self.fileManager = fileManager
        self.loader = loader
    }

    public func `import`(source: URL, into petsDirectory: URL, replaceExisting: Bool = false) throws -> PetImportResult {
        let staging = try makeStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        let package = try stage(source: source, into: staging)
        try rejectLinks(in: package)
        let pet = try loader.loadPackage(at: package)
        try fileManager.createDirectory(at: petsDirectory, withIntermediateDirectories: true)
        let existing = PetLibrary(loader: loader, fileManager: fileManager).scan(at: petsDirectory).valid.first { $0.id == pet.id }
        if existing != nil, !replaceExisting { throw PetImportError.duplicateRequiresReplacement(pet.id) }
        let destination = petsDirectory.appendingPathComponent(package.lastPathComponent, isDirectory: true)
        let backupRoot = try backupDirectory()
        var backup: URL?
        do {
            if fileManager.fileExists(atPath: destination.path) {
                let target = backupRoot.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(destination.lastPathComponent)", isDirectory: true)
                try fileManager.moveItem(at: destination, to: target); backup = target
            }
            try fileManager.moveItem(at: package, to: destination)
            _ = try loader.loadPackage(at: destination)
            trimBackups(in: backupRoot)
            return .init(pet: try loader.loadPackage(at: destination), replaced: existing != nil)
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if let backup { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
    }

    private func stage(source: URL, into staging: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw PetImportError.unsupportedSource }
        if isDirectory.boolValue {
            let target = staging.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: source, to: target)
            return target
        }
        guard source.pathExtension.lowercased() == "zip" else { throw PetImportError.unsupportedSource }
        let entries = try archiveEntries(source)
        let counted = entries.filter { !Self.isJunkArchiveEntry($0) }
        guard counted.count <= 128 else { throw PetImportError.archiveTooLarge }
        for entry in entries where entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
            throw PetImportError.unsafeArchiveEntry(entry)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PetImportError.unsupportedSource }
        return try resolvePackageRoot(in: staging)
    }

    func resolvePackageRoot(in staging: URL) throws -> URL {
        let contents = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let meaningful = contents.filter { !Self.isJunkName($0.lastPathComponent) }
        let directories = meaningful.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = meaningful.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }

        if directories.count == 1, files.isEmpty {
            return directories[0]
        }

        if files.contains(where: { $0.lastPathComponent == "pet.json" }) {
            return try wrapFlatPackage(at: staging, items: meaningful)
        }

        let candidates = directories.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent("pet.json", isDirectory: false).path)
        }
        if candidates.count == 1 {
            return candidates[0]
        }

        throw PetImportError.invalidPackageRoot
    }

    private func wrapFlatPackage(at staging: URL, items: [URL]) throws -> URL {
        let manifestURL = staging.appendingPathComponent("pet.json", isDirectory: false)
        let folderName = try packageFolderName(from: manifestURL)
        let package = staging.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        for item in items where item.lastPathComponent != folderName {
            let destination = package.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                throw PetImportError.invalidPackageRoot
            }
            try fileManager.moveItem(at: item, to: destination)
        }
        return package
    }

    private func packageFolderName(from manifestURL: URL) throws -> String {
        struct ManifestID: Decodable { let id: String? }
        let data = try Data(contentsOf: manifestURL)
        if let decoded = try? JSONDecoder().decode(ManifestID.self, from: data),
           let id = decoded.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty,
           !id.contains("/"),
           !id.contains("\\"),
           id != "." ,
           id != ".." {
            return id
        }
        return "imported-pet"
    }

    private func archiveEntries(_ archive: URL) throws -> [String] {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PetImportError.unsupportedSource }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func rejectLinks(in root: URL) throws {
        let paths = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        while let url = paths?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw PetImportError.unsafeLink(url.lastPathComponent)
            }
        }
    }

    private func makeStagingDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetRunnerImport", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func backupDirectory() throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetRunner/pet-backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func trimBackups(in root: URL) {
        let backups = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: []))?
            .sorted { ($0.path) > ($1.path) } ?? []
        for stale in backups.dropFirst(3) { try? fileManager.removeItem(at: stale) }
    }

    static func isJunkName(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    static func isJunkArchiveEntry(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/")
        return parts.contains("__MACOSX")
            || parts.contains { $0.hasPrefix("._") }
            || entry.hasSuffix(".DS_Store")
    }
}
