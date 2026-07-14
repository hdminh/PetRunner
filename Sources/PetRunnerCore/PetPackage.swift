import CoreGraphics
import Foundation
import ImageIO

public enum SpriteVersion: Int, Codable, CaseIterable {
    case v1 = 1
    case v2 = 2

    public var rowCount: Int { self == .v1 ? 9 : 11 }

    public var expectedSize: CGSize {
        CGSize(width: 1536, height: rowCount * 208)
    }
}

public struct PetDescriptor: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let version: SpriteVersion
    public let packageURL: URL
    public let spritesheetURL: URL

    public init(
        id: String,
        displayName: String,
        description: String?,
        version: SpriteVersion,
        packageURL: URL,
        spritesheetURL: URL
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.packageURL = packageURL
        self.spritesheetURL = spritesheetURL
    }
}

public enum PetLoadError: Error, LocalizedError {
    case manifestMissing(URL)
    case manifestInvalid(String)
    case unsupportedVersion(Int)
    case unsupportedSpritesheetExtension(String)
    case spritesheetOutsidePackage
    case spritesheetMissing(URL)
    case unreadableSpritesheet(URL)
    case invalidAtlasDimensions(expected: CGSize, actual: CGSize)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            "pet.json is missing"
        case let .manifestInvalid(message):
            "pet.json is invalid: \(message)"
        case let .unsupportedVersion(version):
            "spriteVersionNumber \(version) is unsupported"
        case let .unsupportedSpritesheetExtension(ext):
            "spritesheet extension .\(ext) is unsupported"
        case .spritesheetOutsidePackage:
            "spritesheetPath escapes the pet directory"
        case .spritesheetMissing:
            "spritesheet file is missing"
        case .unreadableSpritesheet:
            "spritesheet cannot be decoded"
        case let .invalidAtlasDimensions(expected, actual):
            "atlas is \(Int(actual.width))×\(Int(actual.height)); expected \(Int(expected.width))×\(Int(expected.height))"
        }
    }
}

public protocol AtlasMetadataReading {
    func dimensions(of url: URL) throws -> CGSize
}

public struct ImageIOAtlasMetadataReader: AtlasMetadataReading {
    public init() {}

    public func dimensions(of url: URL) throws -> CGSize {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw PetLoadError.unreadableSpritesheet(url)
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }
}

public struct PetPackageLoader {
    private let metadataReader: any AtlasMetadataReading
    private let fileManager: FileManager

    public init(
        metadataReader: any AtlasMetadataReading = ImageIOAtlasMetadataReader(),
        fileManager: FileManager = .default
    ) {
        self.metadataReader = metadataReader
        self.fileManager = fileManager
    }

    public func loadPackage(at directoryURL: URL) throws -> PetDescriptor {
        let packageURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = packageURL.appendingPathComponent("pet.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PetLoadError.manifestMissing(manifestURL)
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw PetLoadError.manifestInvalid(error.localizedDescription)
        }

        let rawVersion = manifest.spriteVersionNumber ?? 1
        guard let version = SpriteVersion(rawValue: rawVersion) else {
            throw PetLoadError.unsupportedVersion(rawVersion)
        }

        let relativePath = nonempty(manifest.spritesheetPath) ?? "spritesheet.webp"
        let unresolvedSheet = packageURL.appendingPathComponent(relativePath, isDirectory: false)
        let spritesheetURL = unresolvedSheet.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(spritesheetURL, by: packageURL) else {
            throw PetLoadError.spritesheetOutsidePackage
        }

        let ext = spritesheetURL.pathExtension.lowercased()
        guard ext == "webp" || ext == "png" else {
            throw PetLoadError.unsupportedSpritesheetExtension(ext)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: spritesheetURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PetLoadError.spritesheetMissing(spritesheetURL)
        }

        let actualSize = try metadataReader.dimensions(of: spritesheetURL)
        guard actualSize == version.expectedSize else {
            throw PetLoadError.invalidAtlasDimensions(expected: version.expectedSize, actual: actualSize)
        }

        let fallbackID = packageURL.lastPathComponent
        let id = nonempty(manifest.id) ?? fallbackID
        let displayName = nonempty(manifest.displayName) ?? id
        return PetDescriptor(
            id: id,
            displayName: displayName,
            description: nonempty(manifest.description),
            version: version,
            packageURL: packageURL,
            spritesheetURL: spritesheetURL
        )
    }

    private func isContained(_ candidate: URL, by directory: URL) -> Bool {
        let parent = directory.pathComponents
        let child = candidate.pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct Manifest: Decodable {
    let id: String?
    let displayName: String?
    let description: String?
    let spriteVersionNumber: Int?
    let spritesheetPath: String?
}

public struct PetFailure: Identifiable, Hashable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public struct PetScanResult {
    public let valid: [PetDescriptor]
    public let invalid: [PetFailure]

    public init(valid: [PetDescriptor], invalid: [PetFailure]) {
        self.valid = valid
        self.invalid = invalid
    }
}

public struct PetLibrary {
    private let loader: PetPackageLoader
    private let fileManager: FileManager

    public init(
        loader: PetPackageLoader = PetPackageLoader(),
        fileManager: FileManager = .default
    ) {
        self.loader = loader
        self.fileManager = fileManager
    }

    public func scan(at petsURL: URL) -> PetScanResult {
        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: petsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return PetScanResult(
                valid: [],
                invalid: [PetFailure(id: petsURL.lastPathComponent, message: error.localizedDescription)]
            )
        }

        var valid: [PetDescriptor] = []
        var invalid: [PetFailure] = []
        var seenIDs = Set<String>()
        for directory in directories {
            do {
                let pet = try loader.loadPackage(at: directory)
                guard seenIDs.insert(pet.id).inserted else {
                    invalid.append(PetFailure(id: directory.lastPathComponent, message: "duplicate pet id \(pet.id)"))
                    continue
                }
                valid.append(pet)
            } catch {
                invalid.append(
                    PetFailure(
                        id: directory.lastPathComponent,
                        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                )
            }
        }
        return PetScanResult(valid: valid, invalid: invalid)
    }
}
