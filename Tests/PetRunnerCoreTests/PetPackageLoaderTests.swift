import CoreGraphics
import Foundation
import Testing
@testable import PetRunnerCore

struct PetPackageLoaderTests {
    @Test func missingOptionalFieldsUseCodexV1Defaults() throws {
        let directory = try makePackage(json: #"{"description":"Tiny friend"}"#)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let pet = try PetPackageLoader(
            metadataReader: StubMetadataReader(size: CGSize(width: 1536, height: 1872))
        ).loadPackage(at: directory)

        #expect(pet.id == directory.lastPathComponent)
        #expect(pet.displayName == directory.lastPathComponent)
        #expect(pet.description == "Tiny friend")
        #expect(pet.version == .v1)
        #expect(pet.spritesheetURL.lastPathComponent == "spritesheet.webp")
    }

    @Test func v2ManifestRequiresV2Dimensions() throws {
        let directory = try makePackage(
            json: #"{"id":"marmalade","displayName":"Marmalade","spriteVersionNumber":2,"spritesheetPath":"sheet.png"}"#,
            spritesheetName: "sheet.png"
        )
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let pet = try PetPackageLoader(
            metadataReader: StubMetadataReader(size: CGSize(width: 1536, height: 2288))
        ).loadPackage(at: directory)

        #expect(pet.id == "marmalade")
        #expect(pet.version == .v2)
        #expect(pet.spritesheetURL.pathExtension == "png")
    }

    @Test func rejectsSpritesheetOutsidePackage() throws {
        let directory = try makePackage(json: #"{"spritesheetPath":"../outside.webp"}"#)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        do {
            _ = try PetPackageLoader(metadataReader: StubMetadataReader(size: .zero))
                .loadPackage(at: directory)
            Issue.record("Expected spritesheetOutsidePackage")
        } catch PetLoadError.spritesheetOutsidePackage {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsSymlinkThatEscapesPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("pet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"spritesheetPath":"linked.webp"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))
        let outside = root.appendingPathComponent("outside.webp")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.webp"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try PetPackageLoader(metadataReader: StubMetadataReader(size: .zero))
                .loadPackage(at: directory)
            Issue.record("Expected spritesheetOutsidePackage")
        } catch PetLoadError.spritesheetOutsidePackage {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsMissingAndWrongSizedSpritesheets() throws {
        let missing = try makePackage(json: #"{"spritesheetPath":"missing.webp"}"#)
        defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }

        do {
            _ = try PetPackageLoader(metadataReader: StubMetadataReader(size: .zero))
                .loadPackage(at: missing)
            Issue.record("Expected spritesheetMissing")
        } catch PetLoadError.spritesheetMissing {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let wrongSize = try makePackage(json: #"{"spriteVersionNumber":1}"#)
        defer { try? FileManager.default.removeItem(at: wrongSize.deletingLastPathComponent()) }
        do {
            _ = try PetPackageLoader(
                metadataReader: StubMetadataReader(size: CGSize(width: 1536, height: 2288))
            ).loadPackage(at: wrongSize)
            Issue.record("Expected invalidAtlasDimensions")
        } catch PetLoadError.invalidAtlasDimensions {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makePackage(
        json: String,
        spritesheetName: String = "spritesheet.webp"
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sample-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("pet.json"))
        try Data([0]).write(to: directory.appendingPathComponent(spritesheetName))
        return directory
    }
}

private struct StubMetadataReader: AtlasMetadataReading {
    let size: CGSize
    func dimensions(of url: URL) throws -> CGSize { size }
}
