import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PetRunnerCore

struct PetPackageLoaderTests {
    @Test func missingOptionalFieldsUseCodexV1Defaults() throws {
        let directory = try makePackage(json: #"{"description":"Tiny friend"}"#)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let pet = try PetPackageLoader().loadPackage(at: directory)
        #expect(pet.id == directory.lastPathComponent)
        #expect(pet.displayName == directory.lastPathComponent)
        #expect(pet.description == "Tiny friend")
        #expect(pet.version == .v1)
    }

    @Test func v2ManifestRequiresV2Dimensions() throws {
        let directory = try makePackage(
            json: #"{"id":"marmalade","displayName":"Marmalade","spriteVersionNumber":2,"spritesheetPath":"sheet.png"}"#,
            spritesheetName: "sheet.png",
            size: CGSize(width: 1536, height: 2288)
        )
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let pet = try PetPackageLoader().loadPackage(at: directory)
        #expect(pet.id == "marmalade")
        #expect(pet.version == .v2)
        #expect(pet.spritesheetURL.pathExtension == "png")
    }

    @Test func rejectsSpritesheetOutsidePackageAndSymlinkEscapes() throws {
        let directory = try makePackage(json: #"{"spritesheetPath":"../outside.webp"}"#)
        let root = directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAtlas(to: root.appendingPathComponent("outside.webp"), size: CGSize(width: 1536, height: 1872))
        try expectSpritesheetEscape(at: directory)

        let linked = try makePackage(json: #"{"spritesheetPath":"linked.webp"}"#)
        defer { try? FileManager.default.removeItem(at: linked.deletingLastPathComponent()) }
        let external = linked.deletingLastPathComponent().appendingPathComponent("outside.webp")
        try writeAtlas(to: external, size: CGSize(width: 1536, height: 1872))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("linked.webp"), withDestinationURL: external)
        try expectSpritesheetEscape(at: linked)
    }

    @Test func rejectsMissingAndWrongSizedSpritesheets() throws {
        let missing = try makePackage(json: #"{"spritesheetPath":"missing.webp"}"#, includeSpritesheet: false)
        defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }
        do {
            _ = try PetPackageLoader().loadPackage(at: missing)
            Issue.record("Expected missing spritesheet")
        } catch PetLoadError.spritesheetMissing {
        }

        let wrongSize = try makePackage(json: #"{"spriteVersionNumber":1}"#, size: CGSize(width: 1536, height: 2288))
        defer { try? FileManager.default.removeItem(at: wrongSize.deletingLastPathComponent()) }
        do {
            _ = try PetPackageLoader().loadPackage(at: wrongSize)
            Issue.record("Expected invalid atlas dimensions")
        } catch PetLoadError.invalidAtlasDimensions {
        }
    }

    private func makePackage(json: String, spritesheetName: String = "spritesheet.webp", size: CGSize = CGSize(width: 1536, height: 1872), includeSpritesheet: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sample-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("pet.json"))
        if includeSpritesheet { try writeAtlas(to: directory.appendingPathComponent(spritesheetName), size: size) }
        return directory
    }

    private func writeAtlas(to url: URL, size: CGSize) throws {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func expectSpritesheetEscape(at directory: URL) throws {
        do {
            _ = try PetPackageLoader().loadPackage(at: directory)
            Issue.record("Expected spritesheet escape")
        } catch PetLoadError.spritesheetOutsidePackage {
        }
    }
}
