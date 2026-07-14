import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rust owns decode, validation, cropping, and PNG production. This adapter only creates a
/// native image object for AppKit presentation.
public final class SpriteAtlas {
    public static let cellSize = CGSize(width: 192, height: 208)

    public let version: SpriteVersion
    private var handle: UnsafeMutableRawPointer?

    public convenience init(contentsOf url: URL, version: SpriteVersion) throws {
        try self.init(path: url.path, version: version)
    }

    public convenience init(image: CGImage, version: SpriteVersion) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("petrunner-atlas-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PetLoadError.unreadableSpritesheet(temporary)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetLoadError.unreadableSpritesheet(temporary) }
        try self.init(path: temporary.path, version: version)
    }

    private init(path: String, version: SpriteVersion) throws {
        self.version = version
        var newHandle: UnsafeMutableRawPointer?
        let status = path.withCString { RustBridge.shared.atlasCreate($0, Int32(version.rawValue), &newHandle) }
        guard status == RustBridge.ok, let newHandle else {
            throw PetLoadError.unreadableSpritesheet(URL(fileURLWithPath: path))
        }
        handle = newHandle
    }

    deinit { RustBridge.shared.atlasDestroy(handle) }

    public func frame(at address: AtlasAddress) -> CGImage? {
        guard let handle else { return nil }
        let data = try? RustBridge.decodeBuffer { buffer in
            RustBridge.shared.atlasFrame(UnsafeRawPointer(handle), Int32(address.row), Int32(address.column), buffer)
        }
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
