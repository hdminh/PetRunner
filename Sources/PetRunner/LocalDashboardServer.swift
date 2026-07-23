@preconcurrency import Network
import Foundation
import PetRunnerCore

final class LocalDashboardServer: @unchecked Sendable {
    typealias APIHandler = @Sendable (DashboardHTTPRequest) async -> DashboardHTTPResponse

    private let queue = DispatchQueue(label: "vn.hodinhminh.petrunner.dashboard")
    private let assetsDirectory: URL
    private let apiHandler: APIHandler
    private var listener: NWListener?
    private(set) var baseURL: URL?

    init(assetsDirectory: URL, apiHandler: @escaping APIHandler) {
        self.assetsDirectory = assetsDirectory
        self.apiHandler = apiHandler
    }

    func start(preferredPort: UInt16 = 47_835) throws -> URL {
        if let baseURL { return baseURL }
        guard FileManager.default.fileExists(atPath: assetsDirectory.appendingPathComponent("index.html").path) else {
            throw LocalDashboardServerError.missingAssets
        }

        for rawPort in preferredPort...(preferredPort + 20) {
            guard let port = NWEndpoint.Port(rawValue: rawPort), let candidate = try? readyListener(port: port) else { continue }
            listener = candidate
            let url = URL(string: "http://127.0.0.1:\(rawPort)/")!
            baseURL = url
            return url
        }
        throw LocalDashboardServerError.noAvailablePort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
    }

    private func readyListener(port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let candidate = try NWListener(using: parameters)
        let semaphore = DispatchSemaphore(value: 0)
        let startup = ListenerStartupState()
        candidate.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if startup.complete(ready: true, error: nil) { semaphore.signal() }
            case let .failed(error):
                if startup.complete(ready: false, error: error) { semaphore.signal() }
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        candidate.start(queue: queue)
        let signaled = semaphore.wait(timeout: .now() + 1) == .success
        let result = startup.result()
        guard signaled, result.ready, result.error == nil else {
            candidate.cancel()
            throw result.error ?? LocalDashboardServerError.startTimedOut
        }
        return candidate
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var requestData = accumulated
            if let data { requestData.append(data) }
            if requestData.count > DashboardHTTPCodec.maximumHeaderBytes + DashboardHTTPCodec.maximumBodyBytes {
                send(secured(.error(status: 413, code: "payload_too_large", message: "Request is too large.")), on: connection)
                return
            }
            do {
                let request = try DashboardHTTPCodec.parse(requestData)
                route(request, connection: connection)
            } catch DashboardHTTPError.incomplete where !isComplete && error == nil {
                receive(connection, accumulated: requestData)
            } catch DashboardHTTPError.bodyTooLarge {
                send(secured(.error(status: 413, code: "payload_too_large", message: "Request body is too large.")), on: connection)
            } catch {
                send(secured(.error(status: 400, code: "bad_request", message: "Malformed HTTP request.")), on: connection)
            }
        }
    }

    private func route(_ request: DashboardHTTPRequest, connection: NWConnection) {
        guard let baseURL else {
            send(secured(.error(status: 503, code: "dashboard_unavailable", message: "Dashboard is unavailable.")), on: connection)
            return
        }
        let decision = DashboardRouteSecurity.decide(
            request: request,
            expectedOrigin: "http://\(baseURL.host!):\(baseURL.port!)"
        )
        switch decision {
        case .notFound:
            send(secured(.error(status: 404, code: "not_found", message: "Not found.")), on: connection, headOnly: request.method == "HEAD")
            return
        case .forbidden:
            send(secured(.error(status: 403, code: "forbidden", message: "Invalid request origin.")), on: connection)
            return
        case .methodNotAllowed:
            send(secured(.error(status: 405, code: "method_not_allowed", message: "Method not allowed.")), on: connection)
            return
        case .api:
            Task { [apiHandler] in
                let response = await apiHandler(request)
                self.send(self.secured(response), on: connection, headOnly: request.method == "HEAD")
            }
            return
        case let .asset(assetName):
            serve(assetName, request: request, connection: connection)
        }
    }

    private func serve(_ assetName: String, request: DashboardHTTPRequest, connection: NWConnection) {
        let file = assetsDirectory.appendingPathComponent(assetName, isDirectory: false).standardizedFileURL
        let root = assetsDirectory.standardizedFileURL.path + "/"
        guard file.path.hasPrefix(root) else {
            send(secured(.error(status: 404, code: "not_found", message: "Not found.")), on: connection)
            return
        }
        guard let body = try? Data(contentsOf: file) else {
            send(secured(.error(status: 404, code: "not_found", message: "Not found.")), on: connection)
            return
        }
        let contentType: String
        switch file.pathExtension {
        case "css": contentType = "text/css; charset=utf-8"
        case "js", "mjs": contentType = "text/javascript; charset=utf-8"
        case "json": contentType = "application/json; charset=utf-8"
        case "svg": contentType = "image/svg+xml"
        case "png": contentType = "image/png"
        case "woff2": contentType = "font/woff2"
        default: contentType = "text/html; charset=utf-8"
        }
        send(secured(.init(status: 200, headers: ["Content-Type": contentType], body: body)), on: connection, headOnly: request.method == "HEAD")
    }

    private func secured(_ response: DashboardHTTPResponse) -> DashboardHTTPResponse {
        var headers = response.headers
        headers["Cache-Control"] = "no-store"
        headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        headers["Referrer-Policy"] = "no-referrer"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        return DashboardHTTPResponse(status: response.status, headers: headers, body: response.body)
    }

    private func send(_ response: DashboardHTTPResponse, on connection: NWConnection, headOnly: Bool = false) {
        let data = DashboardHTTPCodec.serialize(response, headOnly: headOnly)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ListenerStartupState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var ready = false
    private var error: NWError?

    func complete(ready: Bool, error: NWError?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        self.ready = ready
        self.error = error
        return true
    }

    func result() -> (ready: Bool, error: NWError?) {
        lock.lock()
        defer { lock.unlock() }
        return (ready, error)
    }
}

enum LocalDashboardServerError: Error, LocalizedError {
    case missingAssets
    case noAvailablePort
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .missingAssets: "Dashboard web assets are missing from the application bundle."
        case .noAvailablePort: "No local dashboard port is available."
        case .startTimedOut: "The local dashboard server did not start in time."
        }
    }
}
