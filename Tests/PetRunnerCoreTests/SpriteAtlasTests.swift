import CoreGraphics
import Foundation
import Testing
@testable import PetRunnerCore

struct SpriteAtlasTests {
    @Test func rowsUseTopOriginWithoutVerticalInversion() throws {
        let width = 1536
        let height = 1872
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 208, width: 192, height: 208))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 192, height: 208))
        let image = try #require(context.makeImage())

        let atlas = try SpriteAtlas(image: image, version: .v1)
        let topFrame = try #require(atlas.frame(at: AtlasAddress(row: 0, column: 0)))
        let bottomFrame = try #require(atlas.frame(at: AtlasAddress(row: 8, column: 0)))

        let topPixel = try pixel(topFrame)
        let bottomPixel = try pixel(bottomFrame)
        #expect(topPixel[0] > 240 && topPixel[0] > topPixel[2] * 4)
        #expect(bottomPixel[2] > 240 && bottomPixel[2] > bottomPixel[0] * 4)
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pointer.deallocate() }
        pointer.initialize(repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: pointer,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: pointer, count: 4))
    }
}
