import CoreGraphics
import Foundation
import Testing
@testable import PetRunnerCore

struct PetRemovalServiceTests {
    @Test func removesPackageInsidePetsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        let package = try makePackage(named: "misty", id: "misty", in: pets)
        defer { try? FileManager.default.removeItem(at: root) }

        let removed = try PetRemovalService(
            loader: PetPackageLoader(metadataReader: StubMetadataReader(size: CGSize(width: 1536, height: 1872)))
        ).remove(id: "misty", from: pets)

        #expect(removed.lastPathComponent == "misty")
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func removesSymlinkEntryWithoutDeletingExternalTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)
        let outside = try makePackage(named: "linked", id: "linked", in: root, folderName: "outside-pet")
        let link = pets.appendingPathComponent("linked-pet", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try PetRemovalService(
            loader: PetPackageLoader(metadataReader: StubMetadataReader(size: CGSize(width: 1536, height: 1872)))
        ).remove(id: "linked", from: pets)

        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("pet.json").path))
    }

    @Test func rejectsUnknownAndInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pets = root.appendingPathComponent("pets", isDirectory: true)
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PetRemovalService()

        #expect(throws: PetRemovalError.notFound("missing")) {
            try service.remove(id: "missing", from: pets)
        }
        #expect(throws: PetRemovalError.invalidPetID) {
            try service.remove(id: "../escape", from: pets)
        }
    }

    private func makePackage(
        named: String,
        id: String,
        in petsDirectory: URL,
        folderName: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: petsDirectory, withIntermediateDirectories: true)
        let directory = petsDirectory.appendingPathComponent(folderName ?? named, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(id)","displayName":"\#(named)"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))
        try Data([0]).write(to: directory.appendingPathComponent("spritesheet.webp"))
        return directory
    }
}

private struct StubMetadataReader: AtlasMetadataReading {
    let size: CGSize
    func dimensions(of url: URL) throws -> CGSize { size }
}
