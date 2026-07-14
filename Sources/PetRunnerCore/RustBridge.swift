import Darwin
import Foundation
import CPetRunnerBridge

/// Private dynamic bridge to the Rust domain library. The bridge deliberately has no AppKit
/// dependencies so the same ABI can be loaded by the WPF host.
enum RustBridge {
    typealias Version = @convention(c) (UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias BufferFree = @convention(c) (PetrunnerBuffer) -> Void
    typealias ScanPets = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias AtlasCreate = @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias AtlasDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias AtlasFrame = @convention(c) (UnsafeRawPointer?, Int32, Int32, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias AnimationCreate = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias AnimationDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias AnimationFrameCount = @convention(c) (Int32) -> Int32
    typealias AnimationFrameDuration = @convention(c) (Int32, Int32) -> Double
    typealias AnimationCyclesBeforeIdle = @convention(c) (Int32) -> Int32
    typealias AnimationStart = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias AnimationAdvance = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
    typealias AnimationSnapshotFunction = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<PetrunnerAnimationSnapshot>?) -> Int32
    typealias LookDirection = @convention(c) (Double, Double, Double, UnsafeMutablePointer<PetrunnerAtlasAddress>?) -> Bool
    typealias PhysicsStep = @convention(c) (UnsafeMutablePointer<PetrunnerMotionState>?, PetrunnerSize, PetrunnerRect, Double, Double, Double, Double, Double, UnsafeMutablePointer<PetrunnerPhysicsResult>?) -> Int32
    typealias PhysicsClamp = @convention(c) (Double, Double, PetrunnerSize, PetrunnerRect, UnsafeMutablePointer<PetrunnerMotionState>?) -> Int32
    typealias MonitorStoreCreate = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias MonitorStoreDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias MonitorStoreJson = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias MonitorStoreSnapshot = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias MonitorStoreMutation = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Int32
    typealias MonitorStoreAction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias MonitorDecode = @convention(c) (UnsafePointer<UInt8>?, UInt, UnsafePointer<CChar>?, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias MonitorNormalize = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt, UnsafePointer<CChar>?, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias ProviderDetect = @convention(c) (UnsafePointer<UInt8>?, UInt, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32
    typealias ProviderHooksInstall = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt, UnsafePointer<CChar>?) -> Int32
    typealias ProviderHooksRemove = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias CursorTitle = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<PetrunnerBuffer>?) -> Int32

    static let ok: Int32 = 0

    static let shared = RustBridgeLibrary()

    static func decodeBuffer(_ operation: (UnsafeMutablePointer<PetrunnerBuffer>) -> Int32) throws -> Data {
        var buffer = PetrunnerBuffer(data: nil, len: 0)
        let result = operation(&buffer)
        guard result == ok, let data = buffer.data else { throw RustBridgeError.operationFailed(result) }
        defer { shared.bufferFree(buffer) }
        return Data(bytes: data, count: Int(buffer.len))
    }
}

enum RustBridgeError: LocalizedError {
    case libraryUnavailable([String])
    case missingSymbol(String)
    case operationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .libraryUnavailable(paths): "PetRunner Rust core is unavailable. Looked in: \(paths.joined(separator: ", "))"
        case let .missingSymbol(name): "PetRunner Rust core does not export \(name)"
        case let .operationFailed(code): "PetRunner Rust core operation failed (code \(code))"
        }
    }
}

final class RustBridgeLibrary: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    let version: RustBridge.Version
    let bufferFree: RustBridge.BufferFree
    let scanPets: RustBridge.ScanPets
    let atlasCreate: RustBridge.AtlasCreate
    let atlasDestroy: RustBridge.AtlasDestroy
    let atlasFrame: RustBridge.AtlasFrame
    let animationCreate: RustBridge.AnimationCreate
    let animationDestroy: RustBridge.AnimationDestroy
    let animationFrameCount: RustBridge.AnimationFrameCount
    let animationFrameDuration: RustBridge.AnimationFrameDuration
    let animationCyclesBeforeIdle: RustBridge.AnimationCyclesBeforeIdle
    let animationStart: RustBridge.AnimationStart
    let animationAdvance: RustBridge.AnimationAdvance
    let animationSnapshot: RustBridge.AnimationSnapshotFunction
    let lookDirection: RustBridge.LookDirection
    let physicsStep: RustBridge.PhysicsStep
    let physicsClamp: RustBridge.PhysicsClamp
    let monitorStoreCreate: RustBridge.MonitorStoreCreate
    let monitorStoreDestroy: RustBridge.MonitorStoreDestroy
    let monitorStoreUpsert: RustBridge.MonitorStoreMutation
    let monitorStoreRemove: RustBridge.MonitorStoreMutation
    let monitorStoreSetDisplayName: RustBridge.MonitorStoreMutation
    let monitorStoreClear: RustBridge.MonitorStoreAction
    let monitorStoreSelectPrevious: RustBridge.MonitorStoreAction
    let monitorStoreSelectNext: RustBridge.MonitorStoreAction
    let monitorStoreSnapshot: RustBridge.MonitorStoreSnapshot
    let monitorDecode: RustBridge.MonitorDecode
    let monitorNormalize: RustBridge.MonitorNormalize
    let providerDetect: RustBridge.ProviderDetect
    let providerHooksInstall: RustBridge.ProviderHooksInstall
    let providerHooksRemove: RustBridge.ProviderHooksRemove
    let cursorTitle: RustBridge.CursorTitle

    init() {
        let candidates = Self.libraryCandidates()
        guard let loaded = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            fatalError(RustBridgeError.libraryUnavailable(candidates).localizedDescription)
        }
        handle = loaded
        do {
            version = try Self.symbol("petrunner_bridge_version", from: loaded)
            bufferFree = try Self.symbol("petrunner_buffer_free", from: loaded)
            scanPets = try Self.symbol("petrunner_scan_pets", from: loaded)
            atlasCreate = try Self.symbol("petrunner_atlas_create", from: loaded)
            atlasDestroy = try Self.symbol("petrunner_atlas_destroy", from: loaded)
            atlasFrame = try Self.symbol("petrunner_atlas_frame_png", from: loaded)
            animationCreate = try Self.symbol("petrunner_animation_create", from: loaded)
            animationDestroy = try Self.symbol("petrunner_animation_destroy", from: loaded)
            animationFrameCount = try Self.symbol("petrunner_animation_frame_count", from: loaded)
            animationFrameDuration = try Self.symbol("petrunner_animation_frame_duration", from: loaded)
            animationCyclesBeforeIdle = try Self.symbol("petrunner_animation_cycles_before_idle", from: loaded)
            animationStart = try Self.symbol("petrunner_animation_start", from: loaded)
            animationAdvance = try Self.symbol("petrunner_animation_advance", from: loaded)
            animationSnapshot = try Self.symbol("petrunner_animation_snapshot", from: loaded)
            lookDirection = try Self.symbol("petrunner_look_direction", from: loaded)
            physicsStep = try Self.symbol("petrunner_physics_step", from: loaded)
            physicsClamp = try Self.symbol("petrunner_physics_clamp", from: loaded)
            monitorStoreCreate = try Self.symbol("petrunner_monitor_store_create", from: loaded)
            monitorStoreDestroy = try Self.symbol("petrunner_monitor_store_destroy", from: loaded)
            monitorStoreUpsert = try Self.symbol("petrunner_monitor_store_upsert_json", from: loaded)
            monitorStoreRemove = try Self.symbol("petrunner_monitor_store_remove_json", from: loaded)
            monitorStoreSetDisplayName = try Self.symbol("petrunner_monitor_store_set_display_name_json", from: loaded)
            monitorStoreClear = try Self.symbol("petrunner_monitor_store_clear", from: loaded)
            monitorStoreSelectPrevious = try Self.symbol("petrunner_monitor_store_select_previous", from: loaded)
            monitorStoreSelectNext = try Self.symbol("petrunner_monitor_store_select_next", from: loaded)
            monitorStoreSnapshot = try Self.symbol("petrunner_monitor_store_snapshot_json", from: loaded)
            monitorDecode = try Self.symbol("petrunner_monitor_decode_envelope_json", from: loaded)
            monitorNormalize = try Self.symbol("petrunner_monitor_normalize_json", from: loaded)
            providerDetect = try Self.symbol("petrunner_provider_detect_json", from: loaded)
            providerHooksInstall = try Self.symbol("petrunner_provider_hooks_install", from: loaded)
            providerHooksRemove = try Self.symbol("petrunner_provider_hooks_remove_all", from: loaded)
            cursorTitle = try Self.symbol("petrunner_cursor_title_json", from: loaded)
        } catch {
            dlclose(loaded)
            fatalError(error.localizedDescription)
        }
    }

    deinit { dlclose(handle) }

    private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw RustBridgeError.missingSymbol(name) }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func libraryCandidates() -> [String] {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["PETRUNNER_RUST_LIBRARY"], !explicit.isEmpty { candidates.append(explicit) }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent("libpetrunner_bridge.dylib").path)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libpetrunner_bridge.dylib").path)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/debug/libpetrunner_bridge.dylib").path)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/libpetrunner_bridge.dylib").path)
        return candidates
    }
}

/// Codable boundary DTOs used only to translate the Rust monitor's bounded JSON payloads into
/// existing AppKit-facing values. Business decisions remain in Rust.
private struct RustMonitorDisplayName: Codable {
    let value: String
    let source: String
}

private struct RustMonitorEvent: Codable {
    let provider: String
    let sessionId: String
    let status: String
    let displayName: RustMonitorDisplayName?

    init(_ event: NormalizedAgentEvent) {
        provider = event.provider.rawValue
        sessionId = event.sessionID
        status = event.status.rawValue
        displayName = event.displayName.map {
            RustMonitorDisplayName(value: $0.value, source: $0.source == .prompt ? "prompt" : "nativeProvider")
        }
    }

    func value() -> NormalizedAgentEvent? {
        guard let provider = AgentProvider(rawValue: provider), let status = AgentStatus(rawValue: status) else { return nil }
        let name = displayName.flatMap {
            AgentSessionDisplayName.sanitized($0.value, source: $0.source == "nativeProvider" ? .nativeProvider : .prompt)
        }
        return NormalizedAgentEvent(provider: provider, sessionID: sessionId, status: status, displayName: name)
    }
}

private struct RustMonitorKey: Codable {
    let provider: String
    let sessionId: String

    init(_ key: AgentSessionKey) { provider = key.provider.rawValue; sessionId = key.sessionID }
}

private struct RustMonitorStoreEntry: Decodable {
    let key: RustMonitorKey
    let status: String
    let displayName: RustMonitorDisplayName?

    func value() -> AgentSessionSnapshot? {
        guard let provider = AgentProvider(rawValue: key.provider), let status = AgentStatus(rawValue: status) else { return nil }
        let displayName = displayName.flatMap {
            AgentSessionDisplayName.sanitized($0.value, source: $0.source == "nativeProvider" ? .nativeProvider : .prompt)
        }
        return AgentSessionSnapshot(key: AgentSessionKey(provider: provider, sessionID: key.sessionId), status: status, displayName: displayName)
    }
}

private struct RustMonitorStoreSnapshot: Decodable {
    let entries: [RustMonitorStoreEntry]
    let selectedIndex: Int
}

private struct RustMonitorNameUpdate: Encodable {
    let key: RustMonitorKey
    let displayName: RustMonitorDisplayName
}

private struct RustProviderDetection: Decodable {
    let provider: String
    let isDetected: Bool
}

public enum RustMonitor {
    public static func decodeEnvelope(_ data: Data, token: String) -> NormalizedAgentEvent? {
        let output = try? RustBridge.decodeBuffer { buffer in
            data.withUnsafeBytes { bytes in
                token.withCString { RustBridge.shared.monitorDecode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), $0, buffer) }
            }
        }
        guard let output else { return nil }
        return try? JSONDecoder().decode(RustMonitorEvent.self, from: output).value()
    }

    public static func normalize(provider: AgentProvider, payload: Data, event: String) -> NormalizedAgentEvent? {
        let output = try? RustBridge.decodeBuffer { buffer in
            provider.rawValue.withCString { providerName in
                event.withCString { eventName in
                    payload.withUnsafeBytes { bytes in
                        RustBridge.shared.monitorNormalize(providerName, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(payload.count), eventName, buffer)
                    }
                }
            }
        }
        guard let output else { return nil }
        return try? JSONDecoder().decode(RustMonitorEvent.self, from: output).value()
    }

    public static func detect(existingPaths: Set<String>) -> [ProviderDetection] {
        guard let data = try? JSONEncoder().encode(existingPaths),
              let output = try? RustBridge.decodeBuffer({ buffer in
                  data.withUnsafeBytes { bytes in RustBridge.shared.providerDetect(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), buffer) }
              }),
              let detections = try? JSONDecoder().decode([RustProviderDetection].self, from: output)
        else { return [] }
        return detections.compactMap { detection in
            AgentProvider(rawValue: detection.provider).map { ProviderDetection(provider: $0, isDetected: detection.isDetected) }
        }
    }

    public static func installHooks(_ providers: [AgentProvider], executablePath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let names = providers.map(\.rawValue)
        let data = try JSONEncoder().encode(names)
        let result = home.path.withCString { homePath in
            executablePath.withCString { executable in
                data.withUnsafeBytes { bytes in RustBridge.shared.providerHooksInstall(homePath, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), executable) }
            }
        }
        guard result == RustBridge.ok else { throw RustBridgeError.operationFailed(result) }
    }

    public static func removeAllHooks(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let result = home.path.withCString { RustBridge.shared.providerHooksRemove($0) }
        guard result == RustBridge.ok else { throw RustBridgeError.operationFailed(result) }
    }

    public static func cursorTitle(database: URL, conversationID: String) -> AgentSessionDisplayName? {
        let output = try? RustBridge.decodeBuffer { buffer in
            database.path.withCString { databasePath in
                conversationID.withCString { identifier in RustBridge.shared.cursorTitle(databasePath, identifier, buffer) }
            }
        }
        guard let output, let name = try? JSONDecoder().decode(RustMonitorDisplayName.self, from: output) else { return nil }
        return AgentSessionDisplayName.sanitized(name.value, source: name.source == "nativeProvider" ? .nativeProvider : .prompt)
    }
}

public final class RustAgentSessionStore {
    private var handle: UnsafeMutableRawPointer?

    public init() {
        var value: UnsafeMutableRawPointer?
        let result = RustBridge.shared.monitorStoreCreate(&value)
        precondition(result == RustBridge.ok && value != nil, RustBridgeError.operationFailed(result).localizedDescription)
        handle = value
    }

    deinit { RustBridge.shared.monitorStoreDestroy(handle) }

    public var entries: [AgentSessionSnapshot] { snapshot.entries.compactMap { $0.value() } }
    public var selectedIndex: Int { snapshot.selectedIndex }
    public var selected: AgentSessionSnapshot? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }

    public func upsert(_ event: NormalizedAgentEvent) { mutate(RustMonitorEvent(event), using: RustBridge.shared.monitorStoreUpsert) }
    public func selectPrevious() { require(RustBridge.shared.monitorStoreSelectPrevious(handle)) }
    public func selectNext() { require(RustBridge.shared.monitorStoreSelectNext(handle)) }
    public func removeAll() { require(RustBridge.shared.monitorStoreClear(handle)) }

    @discardableResult
    public func remove(_ key: AgentSessionKey) -> Bool {
        let found = entries.contains { $0.key == key }
        mutate(RustMonitorKey(key), using: RustBridge.shared.monitorStoreRemove)
        return found
    }

    @discardableResult
    public func setDisplayName(_ displayName: AgentSessionDisplayName, for key: AgentSessionKey) -> Bool {
        guard entries.contains(where: { $0.key == key }) else { return false }
        let source = displayName.source == .nativeProvider ? "nativeProvider" : "prompt"
        mutate(RustMonitorNameUpdate(key: RustMonitorKey(key), displayName: RustMonitorDisplayName(value: displayName.value, source: source)), using: RustBridge.shared.monitorStoreSetDisplayName)
        return true
    }

    private var snapshot: RustMonitorStoreSnapshot {
        guard let data = try? RustBridge.decodeBuffer({ buffer in RustBridge.shared.monitorStoreSnapshot(handle, buffer) }),
              let decoded = try? JSONDecoder().decode(RustMonitorStoreSnapshot.self, from: data)
        else { return RustMonitorStoreSnapshot(entries: [], selectedIndex: 0) }
        return decoded
    }

    private func mutate<T: Encodable>(_ value: T, using operation: RustBridge.MonitorStoreMutation) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let result = data.withUnsafeBytes { bytes in operation(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count)) }
        require(result)
    }

    private func require(_ result: Int32) {
        precondition(result == RustBridge.ok, RustBridgeError.operationFailed(result).localizedDescription)
    }
}
