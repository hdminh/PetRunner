import CoreGraphics
import Foundation

/// Values used by the native hosts; Rust validates all package contents before these are built.
public enum SpriteVersion: Int, Codable, CaseIterable {
    case v1 = 1
    case v2 = 2

    public var rowCount: Int { self == .v1 ? 9 : 11 }
    public var expectedSize: CGSize { CGSize(width: 1536, height: rowCount * 208) }
}

public struct PetDescriptor: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let version: SpriteVersion
    public let packageURL: URL
    public let spritesheetURL: URL

    public init(id: String, displayName: String, description: String?, version: SpriteVersion, packageURL: URL, spritesheetURL: URL) {
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
        case .manifestMissing: "pet.json is missing"
        case let .manifestInvalid(message): "pet.json is invalid: \(message)"
        case let .unsupportedVersion(version): "spriteVersionNumber \(version) is unsupported"
        case let .unsupportedSpritesheetExtension(ext): "spritesheet extension .\(ext) is unsupported"
        case .spritesheetOutsidePackage: "spritesheetPath escapes the pet directory"
        case .spritesheetMissing: "spritesheet file is missing"
        case .unreadableSpritesheet: "spritesheet cannot be decoded"
        case let .invalidAtlasDimensions(expected, actual): "atlas is \(Int(actual.width))×\(Int(actual.height)); expected \(Int(expected.width))×\(Int(expected.height))"
        }
    }
}

/// Compatibility protocol retained for downstream source compatibility. Rust performs actual
/// image metadata reads and decode validation.
public protocol AtlasMetadataReading { func dimensions(of url: URL) throws -> CGSize }
public struct ImageIOAtlasMetadataReader: AtlasMetadataReading {
    public init() {}
    public func dimensions(of url: URL) throws -> CGSize { throw PetLoadError.unreadableSpritesheet(url) }
}

public struct PetPackageLoader {
    public init(metadataReader _: any AtlasMetadataReading = ImageIOAtlasMetadataReader(), fileManager _: FileManager = .default) {}

    public func loadPackage(at directoryURL: URL) throws -> PetDescriptor {
        let parent = directoryURL.deletingLastPathComponent()
        let result = PetLibrary().scan(at: parent)
        let resolved = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        if let pet = result.valid.first(where: {
            $0.packageURL.standardizedFileURL.resolvingSymlinksInPath().path == resolved.path
        }) { return pet }
        let failure = result.invalid.first(where: { $0.id == directoryURL.lastPathComponent })
        let message = failure?.message ?? "package could not be loaded"
        if message.contains("escapes the pet directory") { throw PetLoadError.spritesheetOutsidePackage }
        if message.contains("spritesheet file is missing") { throw PetLoadError.spritesheetMissing(directoryURL) }
        if message.hasPrefix("atlas is ") { throw PetLoadError.invalidAtlasDimensions(expected: .zero, actual: .zero) }
        if message.contains("cannot be decoded") { throw PetLoadError.unreadableSpritesheet(directoryURL) }
        throw PetLoadError.manifestInvalid(message)
    }
}

public struct PetFailure: Identifiable, Hashable, Decodable {
    public let id: String
    public let message: String
    public init(id: String, message: String) { self.id = id; self.message = message }
}

public struct PetScanResult {
    public let valid: [PetDescriptor]
    public let invalid: [PetFailure]
    public init(valid: [PetDescriptor], invalid: [PetFailure]) { self.valid = valid; self.invalid = invalid }
}

public struct PetLibrary {
    public init() {}

    public func scan(at petsURL: URL) -> PetScanResult {
        guard let data = try? petsURL.path.withCString({ path in
            try RustBridge.decodeBuffer { buffer in RustBridge.shared.scanPets(path, buffer) }
        }), let payload = try? JSONDecoder().decode(RustPetScan.self, from: data)
        else { return PetScanResult(valid: [], invalid: [PetFailure(id: petsURL.lastPathComponent, message: "PetRunner Rust core could not scan this directory")]) }
        let pets = payload.valid.compactMap(PetDescriptor.init)
        return PetScanResult(valid: pets, invalid: payload.invalid)
    }
}

private struct RustPetScan: Decodable {
    let valid: [RustPetDescriptor]
    let invalid: [PetFailure]
}

private struct RustPetDescriptor: Decodable {
    let id: String
    let displayName: String
    let description: String?
    let version: Int
    let packagePath: String
    let spritesheetPath: String
}

private extension PetDescriptor {
    init?(_ payload: RustPetDescriptor) {
        guard let version = SpriteVersion(rawValue: payload.version) else { return nil }
        self.init(
            id: payload.id,
            displayName: payload.displayName,
            description: payload.description,
            version: version,
            packageURL: URL(fileURLWithPath: payload.packagePath, isDirectory: true),
            spritesheetURL: URL(fileURLWithPath: payload.spritesheetPath)
        )
    }
}
