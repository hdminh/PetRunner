import CoreGraphics
import Foundation
import ImageIO

public final class SpriteAtlas {
    public static let cellSize = CGSize(width: 192, height: 208)

    public let version: SpriteVersion
    private let frames: [AtlasAddress: CGImage]

    public convenience init(contentsOf url: URL, version: SpriteVersion) throws {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw PetLoadError.unreadableSpritesheet(url)
        }
        try self.init(image: image, version: version)
    }

    public init(image: CGImage, version: SpriteVersion) throws {
        let actual = CGSize(width: image.width, height: image.height)
        guard actual == version.expectedSize else {
            throw PetLoadError.invalidAtlasDimensions(expected: version.expectedSize, actual: actual)
        }
        self.version = version

        var cropped: [AtlasAddress: CGImage] = [:]
        for row in 0..<version.rowCount {
            for column in 0..<8 {
                let rect = CGRect(
                    x: column * Int(Self.cellSize.width),
                    y: row * Int(Self.cellSize.height),
                    width: Int(Self.cellSize.width),
                    height: Int(Self.cellSize.height)
                )
                if let frame = image.cropping(to: rect) {
                    cropped[AtlasAddress(row: row, column: column)] = frame
                }
            }
        }
        frames = cropped
    }

    public func frame(at address: AtlasAddress) -> CGImage? {
        frames[address]
    }
}
