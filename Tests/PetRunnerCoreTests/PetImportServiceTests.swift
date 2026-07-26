import CoreGraphics
import Foundation
import Testing
@testable import PetRunnerCore

struct PetImportServiceTests {
    @Test func importsFlatZipLikeCodexPetsDownload() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let flat = workspace.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try writePetFiles(in: flat, id: "maomao")
        let archive = workspace.appendingPathComponent("maomao.zip")
        try zipContents(of: flat, to: archive)

        let pets = workspace.appendingPathComponent("pets", isDirectory: true)
        let result = try PetImportService(loader: stubLoader()).import(source: archive, into: pets)
        #expect(result.pet.id == "maomao")
        #expect(FileManager.default.fileExists(atPath: pets.appendingPathComponent("maomao/pet.json").path))
    }

    @Test func importsNestedZipWithMacOSXJunk() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let nestedRoot = workspace.appendingPathComponent("nested-src", isDirectory: true)
        let package = nestedRoot.appendingPathComponent("sample-pet", isDirectory: true)
        let junk = nestedRoot.appendingPathComponent("__MACOSX", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try writePetFiles(in: package, id: "sample-pet")
        try Data([0]).write(to: junk.appendingPathComponent("._junk"))
        let archive = workspace.appendingPathComponent("nested.zip")
        try zipContents(of: nestedRoot, to: archive)

        let pets = workspace.appendingPathComponent("pets", isDirectory: true)
        let result = try PetImportService(loader: stubLoader()).import(source: archive, into: pets)
        #expect(result.pet.id == "sample-pet")
    }

    @Test func resolvePackageRootWrapsFlatStaging() throws {
        let staging = try makeWorkspace().appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writePetFiles(in: staging, id: "flat-pet")

        let root = try PetImportService(loader: stubLoader()).resolvePackageRoot(in: staging)
        #expect(root.lastPathComponent == "flat-pet")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pet.json").path))
    }

    @Test func prefersSelectedThenMaomao() {
        let pets = [
            stubPet(id: "aladin"),
            stubPet(id: "maomao"),
            stubPet(id: "zebra"),
        ]
        #expect(PetSelectionOrdering.orderedCandidates(from: pets, selectedID: nil).map(\.id) == ["maomao", "aladin", "zebra"])
        #expect(PetSelectionOrdering.orderedCandidates(from: pets, selectedID: "zebra").map(\.id) == ["zebra", "aladin", "maomao"])
    }

    @Test func installsBundledDefaultOnlyWhenMissing() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundled = workspace.appendingPathComponent("bundled/maomao", isDirectory: true)
        let pets = workspace.appendingPathComponent("pets", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try writePetFiles(in: bundled, id: "maomao")

        let installer = DefaultPetInstaller(loader: stubLoader())
        #expect(try installer.installIfMissing(bundledPackage: bundled, into: pets) == true)
        #expect(try installer.installIfMissing(bundledPackage: bundled, into: pets) == false)
        #expect(FileManager.default.fileExists(atPath: pets.appendingPathComponent("maomao/pet.json").path))
    }

    @Test func installsAllMissingBundledPets() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundledRoot = workspace.appendingPathComponent("DefaultPets", isDirectory: true)
        let misty = bundledRoot.appendingPathComponent("misty", isDirectory: true)
        let broken = bundledRoot.appendingPathComponent("broken", isDirectory: true)
        let pets = workspace.appendingPathComponent("pets", isDirectory: true)
        try FileManager.default.createDirectory(at: misty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try writePetFiles(in: misty, id: "misty")
        try Data(#"{"id":"broken"}"#.utf8).write(to: broken.appendingPathComponent("pet.json"))

        let installer = DefaultPetInstaller(loader: stubLoader())
        #expect(try installer.installAllMissing(bundledRoot: bundledRoot, into: pets) == 1)
        #expect(FileManager.default.fileExists(atPath: pets.appendingPathComponent("misty/pet.json").path))
        #expect(!FileManager.default.fileExists(atPath: pets.appendingPathComponent("broken", isDirectory: true).path))
        #expect(try installer.installAllMissing(bundledRoot: bundledRoot, into: pets) == 0)
    }

    @Test func rejectsUnsafePetIDsWhenSeeding() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let pets = workspace.appendingPathComponent("pets", isDirectory: true)
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)

        let escapePkg = workspace.appendingPathComponent("escape-pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: escapePkg, withIntermediateDirectories: true)
        try writePetFiles(in: escapePkg, id: "../escape")

        let installer = DefaultPetInstaller(loader: stubLoader())
        do {
            _ = try installer.installIfMissing(bundledPackage: escapePkg, into: pets)
            Issue.record("expected relative escape id to throw")
        } catch let error as DefaultPetInstallError {
            #expect(error == .unsafePetID("../escape"))
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape", isDirectory: true).path))

        let rootedPkg = workspace.appendingPathComponent("rooted-pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: rootedPkg, withIntermediateDirectories: true)
        try writePetFiles(in: rootedPkg, id: "/tmp/petrunner-install-escape-test")
        do {
            _ = try installer.installIfMissing(bundledPackage: rootedPkg, into: pets)
            Issue.record("expected rooted id to throw")
        } catch let error as DefaultPetInstallError {
            #expect(error == .unsafePetID("/tmp/petrunner-install-escape-test"))
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/petrunner-install-escape-test"))

        #expect(try DefaultPetInstaller.requireSafePetID("  safe-pet  ") == "safe-pet")
    }

    private func stubLoader() -> PetPackageLoader {
        PetPackageLoader(metadataReader: ImportStubMetadataReader(size: CGSize(width: 1536, height: 1872)))
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePetFiles(in directory: URL, id: String) throws {
        let json = #"{"id":"\#(id)","displayName":"\#(id)","spritesheetPath":"spritesheet.webp"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("pet.json"))
        try Data([0]).write(to: directory.appendingPathComponent("spritesheet.webp"))
    }

    private func zipContents(of directory: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PetImportServiceTests", code: 1)
        }
    }

    private func stubPet(id: String) -> PetDescriptor {
        PetDescriptor(
            id: id,
            displayName: id,
            description: nil,
            version: .v1,
            packageURL: URL(fileURLWithPath: "/tmp/\(id)"),
            spritesheetURL: URL(fileURLWithPath: "/tmp/\(id)/spritesheet.webp")
        )
    }
}

private struct ImportStubMetadataReader: AtlasMetadataReading {
    let size: CGSize
    func dimensions(of url: URL) throws -> CGSize { size }
}
