import AppKit
import Foundation
import PetRunnerCore

@MainActor
struct DashboardPetsHandler {
    let deps: DashboardAPIDependencies

    func previewResponse(path: String, query: [String: String]) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "pets", pieces[2] == "preview",
              let pet = deps.petState().pets.first(where: { $0.id == String(pieces[1]) }),
              let atlas = try? SpriteAtlas(contentsOf: pet.spritesheetURL, version: pet.version)
        else { return DashboardAPIShared.notFound() }
        let maxRow = pet.version.rowCount - 1
        let address: AtlasAddress
        if pet.version == .v2, let lookIndex = query["look"].flatMap(Int.init), let look = LookDirection.atlasAddress(for: lookIndex) {
            address = look
        } else if let row = query["row"].flatMap(Int.init), (0...maxRow).contains(row) {
            let column = clampedFrame(query["frame"] ?? query["column"], maximum: 7)
            address = AtlasAddress(row: row, column: column)
        } else {
            let action = query["action"].flatMap(AnimationState.init(rawValue:)) ?? .idle
            let maxFrame = max(0, action.frameDurations.count - 1)
            let column = clampedFrame(query["frame"] ?? query["column"], maximum: maxFrame)
            address = AtlasAddress(row: action.row, column: column)
        }
        guard let image = atlas.frame(at: address), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return .error(status: 409, code: "preview_unavailable", message: "Pet preview is unavailable.")
        }
        return DashboardHTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"], body: data)
    }

    func spritesheetResponse(path: String) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "pets", pieces[2] == "spritesheet",
              let pet = deps.petState().pets.first(where: { $0.id == String(pieces[1]) }),
              let data = try? Data(contentsOf: pet.spritesheetURL)
        else { return DashboardAPIShared.notFound() }
        let contentType: String
        switch pet.spritesheetURL.pathExtension.lowercased() {
        case "png": contentType = "image/png"
        case "webp": contentType = "image/webp"
        default: contentType = "application/octet-stream"
        }
        return DashboardHTTPResponse(status: 200, headers: ["Content-Type": contentType, "Cache-Control": "no-store"], body: data)
    }

    func updatePet(body: Data) -> DashboardHTTPResponse {
        guard let object = DashboardAPIShared.jsonObject(body) else { return DashboardAPIShared.invalidJSON() }
        if let id = object["id"] as? String {
            guard deps.petState().pets.contains(where: { $0.id == id }) else {
                return .error(status: 400, code: "invalid_pet", message: "Unknown pet.")
            }
            deps.onSelectPet(id)
        }
        if let width = DashboardAPIShared.number(object["width"]) {
            guard [80, 112, 160, 224].contains(where: { abs(Double($0) - width) < 0.5 }) else {
                return .error(status: 400, code: "invalid_width", message: "Unsupported pet width.")
            }
            deps.onSetWidth(CGFloat(width))
        }
        return .json(object: ["ok": true])
    }

    func updateAutonomy(body: Data) -> DashboardHTTPResponse {
        guard let object = DashboardAPIShared.jsonObject(body), let enabled = object["enabled"] as? Bool,
              let minimum = DashboardAPIShared.number(object["minimumWait"]), let maximum = DashboardAPIShared.number(object["maximumWait"]),
              let names = object["actions"] as? [String]
        else { return DashboardAPIShared.invalidJSON() }
        let actions = Set(names.compactMap(AutonomousActionKind.init(rawValue:)))
        guard actions.count == names.count,
              let configuration = AutonomyConfiguration(minimumWait: minimum, maximumWait: maximum, enabledActions: actions)
        else { return .error(status: 400, code: "invalid_autonomy", message: "Invalid autonomy configuration.") }
        deps.onSetAutonomy(enabled, configuration)
        return .json(object: ["ok": true])
    }

    func removePet(path: String) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0] == "pets" else { return DashboardAPIShared.notFound() }
        let rawID = String(pieces[1])
        let id = rawID.removingPercentEncoding ?? rawID
        guard !id.isEmpty, !id.contains("/"), id != "." && id != ".." else {
            return .error(status: 400, code: "invalid_pet", message: "Invalid pet id.")
        }
        do {
            try deps.onRemovePet(id)
            let selected = deps.petState().selectedPetID
            return .json(object: [
                "ok": true,
                "removed": id,
                "selectedID": selected as Any? ?? NSNull()
            ])
        } catch let error as PetRemovalError {
            switch error {
            case .notFound:
                return .error(status: 404, code: "pet_not_found", message: error.localizedDescription)
            case .escapesPetsDirectory, .invalidPetID:
                return .error(status: 400, code: "invalid_pet_path", message: error.localizedDescription)
            }
        } catch {
            return .error(
                status: 500,
                code: "remove_failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    func petJSON(_ pet: PetDescriptor) -> [String: Any] {
        var json: [String: Any] = [
            "id": pet.id,
            "name": pet.displayName,
            "description": pet.description as Any? ?? NSNull(),
            "version": pet.version.rawValue
        ]
        let extras = optionalManifestFields(at: pet.packageURL)
        if let author = extras.author { json["author"] = author }
        if let tags = extras.tags { json["tags"] = tags }
        if let packageVersion = extras.packageVersion { json["packageVersion"] = packageVersion }
        if let kind = extras.kind { json["kind"] = kind }
        return json
    }

    func optionalManifestFields(at packageURL: URL) -> (author: String?, tags: [String]?, packageVersion: String?, kind: String?) {
        let manifestURL = packageURL.appendingPathComponent("pet.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, nil, nil) }
        let author = nonemptyString(object["author"] ?? object["creator"] ?? object["by"])
        let packageVersion = nonemptyString(object["packageVersion"] ?? object["version"]).flatMap { value in
            Int(value) != nil ? nil : value
        }
        let kind = nonemptyString(object["kind"])
        let tags: [String]?
        if let rawTags = object["tags"] as? [String] {
            let cleaned = rawTags.compactMap(nonemptyString)
            tags = cleaned.isEmpty ? nil : cleaned
        } else {
            tags = nil
        }
        return (author, tags, packageVersion, kind)
    }

    func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func clampedFrame(_ raw: String?, maximum: Int) -> Int {
        guard let value = raw.flatMap(Int.init) else { return 0 }
        return min(max(0, value), maximum)
    }
}
