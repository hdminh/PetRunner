import Foundation

public enum DashboardHTTPError: Error, Equatable {
    case incomplete
    case malformed
    case headerTooLarge
    case bodyTooLarge
}

public struct DashboardHTTPRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    public let path: String
    public let queryItems: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        target: String,
        path: String,
        queryItems: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.target = target
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }
}

public struct DashboardHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(status: Int = 200, object: Any) -> DashboardHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return DashboardHTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    public static func error(status: Int, code: String, message: String) -> DashboardHTTPResponse {
        json(status: status, object: ["code": code, "message": message])
    }
}

public enum DashboardHTTPCodec {
    public static let maximumHeaderBytes = 32 * 1_024
    public static let maximumBodyBytes = 1_048_576

    public static func parse(_ data: Data) throws -> DashboardHTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes { throw DashboardHTTPError.headerTooLarge }
            throw DashboardHTTPError.incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { throw DashboardHTTPError.malformed }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw DashboardHTTPError.malformed }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw DashboardHTTPError.malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw DashboardHTTPError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw DashboardHTTPError.malformed }
            headers[name] = value
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { throw DashboardHTTPError.malformed }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else { throw DashboardHTTPError.bodyTooLarge }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { throw DashboardHTTPError.incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(parts[1])
        guard let components = URLComponents(string: target), target.hasPrefix("/"), let path = components.percentEncodedPath.removingPercentEncoding else {
            throw DashboardHTTPError.malformed
        }
        var queryItems: [String: String] = [:]
        for item in components.queryItems ?? [] where queryItems[item.name] == nil {
            queryItems[item.name] = item.value ?? ""
        }
        return DashboardHTTPRequest(
            method: String(parts[0]).uppercased(),
            target: target,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    public static func serialize(_ response: DashboardHTTPResponse, headOnly: Bool = false) -> Data {
        let reasons = [
            200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request",
            403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
            409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error",
            503: "Service Unavailable"
        ]
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        var text = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Response")\r\n"
        for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if !headOnly { data.append(response.body) }
        return data
    }
}

public enum DashboardRouteDecision: Equatable, Sendable {
    case api
    case asset(String)
    case forbidden
    case notFound
    case methodNotAllowed
}

public enum DashboardRouteSecurity {
    /// Flat files Vite copies from `DashboardWeb/public/` plus the HTML shell.
    public static let defaultAssets: Set<String> = [
        "index.html",
        "favicon.svg",
        "favicon-32.png",
        "favicon-48.png",
        "apple-touch-icon.png",
    ]

    public static func decide(
        request: DashboardHTTPRequest,
        expectedOrigin: String,
        assets: Set<String> = defaultAssets
    ) -> DashboardRouteDecision {
        guard request.path.hasPrefix("/") else { return .notFound }
        let relativePath = String(request.path.dropFirst())
        if relativePath == "api/v2" || relativePath.hasPrefix("api/v2/") {
            if request.method == "GET" || request.method == "HEAD" { return .api }
            return request.headers["origin"] == expectedOrigin ? .api : .forbidden
        }
        guard request.method == "GET" || request.method == "HEAD" else { return .methodNotAllowed }
        let assetName = relativePath.isEmpty ? "index.html" : relativePath
        let components = assetName.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."), !assetName.hasPrefix("/"),
              assets.contains(assetName) || (assetName.hasPrefix("assets/") && components.count == 2)
        else { return .notFound }
        return .asset(assetName)
    }
}
