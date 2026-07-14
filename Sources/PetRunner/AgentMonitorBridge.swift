import Foundation
import Network
import PetRunnerCore

final class AgentMonitorBridge: @unchecked Sendable {
    var onEvent: ((NormalizedAgentEvent) -> Void)?

    private var listener: NWListener?
    private var token = ""

    func start() throws {
        guard listener == nil else { return }
        token = UUID().uuidString
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: .global(qos: .utility))
            self.receiveEnvelope(from: connection)
        }
        listener.start(queue: .global(qos: .utility))
        _ = ready.wait(timeout: .now() + .seconds(1))
        guard case .ready = listener.state, let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "PetRunner", code: 1)
        }
        self.listener = listener
        try Self.writeDescriptor(AgentMonitorRuntimeDescriptor(port: port.rawValue, token: token))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        token = ""
        Self.removeDescriptor()
    }

    static let descriptorURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PetRunner/agent-monitor.json")

    static func removeDescriptor() {
        try? FileManager.default.removeItem(at: descriptorURL)
    }

    private func receiveEnvelope(from connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: AgentMonitorEnvelope.maximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var completePayload = buffered
            if let data { completePayload.append(data) }
            guard completePayload.count <= AgentMonitorEnvelope.maximumBytes + 4 else { connection.cancel(); return }
            if let payload = Self.payload(from: completePayload) {
                defer { connection.cancel() }
                guard let event = try? AgentMonitorEnvelope.decode(payload, expectedToken: self.token) else { return }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            } else if !isComplete && error == nil {
                self.receiveEnvelope(from: connection, buffered: completePayload)
            } else {
                connection.cancel()
            }
        }
    }

    private static func payload(from frame: Data) -> Data? {
        guard frame.count >= 4 else { return nil }
        let expectedLength = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard expectedLength > 0, expectedLength <= AgentMonitorEnvelope.maximumBytes,
              frame.count >= Int(expectedLength) + 4
        else { return nil }
        return frame.dropFirst(4).prefix(Int(expectedLength))
    }

    private static func writeDescriptor(_ descriptor: AgentMonitorRuntimeDescriptor) throws {
        let directory = descriptorURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(descriptor)
        try data.write(to: descriptorURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptorURL.path)
    }
}

enum AgentMonitorHookRunner {
    static func run(arguments: [String]) -> Int32 {
        guard let providerRaw = value(after: "--provider", in: arguments),
              let provider = AgentProvider(rawValue: providerRaw),
              let event = value(after: "--event", in: arguments)
        else { return 0 }

        if provider == .cursor { FileHandle.standardOutput.write(Data("{}\n".utf8)) }
        let input: Data
        do {
            input = try FileHandle.standardInput.read(upToCount: 64 * 1024 + 1) ?? Data()
        } catch {
            return 0
        }
        guard input.count <= 64 * 1024,
              let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let normalized = ProviderHookConfiguration(provider: provider).normalize(payload: payload, eventName: event),
              let descriptorData = try? Data(contentsOf: AgentMonitorBridge.descriptorURL),
              let descriptor = try? JSONDecoder().decode(AgentMonitorRuntimeDescriptor.self, from: descriptorData)
        else { return 0 }

        let envelope = AgentMonitorEnvelope(token: descriptor.token, provider: normalized.provider, sessionID: normalized.sessionID, status: normalized.status)
        guard let data = try? JSONEncoder().encode(envelope), let port = NWEndpoint.Port(rawValue: descriptor.port) else { return 0 }
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        let frame = header + data
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let finished = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: frame, completion: .contentProcessed { _ in finished.signal() })
            case .failed, .cancelled: finished.signal()
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = finished.wait(timeout: .now() + .milliseconds(250))
        connection.cancel()
        return 0
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
