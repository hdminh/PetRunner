import Foundation
import PetRunnerCore
import Testing

@Suite("Dashboard HTTP")
struct DashboardHTTPTests {
    @Test func parsesBodyHeadersAndQuery() throws {
        let body = Data(#"{"width":160}"#.utf8)
        var request = Data("PUT /secret/api/v2/budgets?source=codex HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)

        let parsed = try DashboardHTTPCodec.parse(request)
        #expect(parsed.method == "PUT")
        #expect(parsed.path == "/secret/api/v2/budgets")
        #expect(parsed.queryItems["source"] == "codex")
        #expect(parsed.headers["content-type"] == "application/json")
        #expect(parsed.body == body)
    }

    @Test func rejectsIncompleteAndOversizedBodies() {
        #expect(throws: DashboardHTTPError.incomplete) {
            try DashboardHTTPCodec.parse(Data("GET / HTTP/1.1\r\nHost: local".utf8))
        }
        #expect(throws: DashboardHTTPError.bodyTooLarge) {
            try DashboardHTTPCodec.parse(Data("POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8))
        }
    }

    @Test func serializesSecurityNeutralHTTPResponse() throws {
        let response = DashboardHTTPResponse.json(object: ["ok": true])
        let data = DashboardHTTPCodec.serialize(response)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length:"))
        #expect(text.hasSuffix(#"{"ok":true}"#))
    }

    @Test func protectsTokenRouteAndMutationOrigin() {
        let origin = "http://127.0.0.1:47835"
        let allowed = DashboardHTTPRequest(
            method: "PUT", target: "/api/v2/budgets", path: "/api/v2/budgets",
            headers: ["origin": origin]
        )
        #expect(DashboardRouteSecurity.decide(request: allowed, expectedOrigin: origin) == .api)

        let foreign = DashboardHTTPRequest(method: "PUT", target: allowed.target, path: allowed.path)
        #expect(DashboardRouteSecurity.decide(request: foreign, expectedOrigin: origin) == .forbidden)
    }

    @Test func servesOnlyAllowListedFlatAssets() {
        let index = DashboardHTTPRequest(method: "GET", target: "/", path: "/")
        #expect(DashboardRouteSecurity.decide(request: index, expectedOrigin: "") == .asset("index.html"))
        let favicon = DashboardHTTPRequest(method: "GET", target: "/favicon.svg", path: "/favicon.svg")
        #expect(DashboardRouteSecurity.decide(request: favicon, expectedOrigin: "") == .asset("favicon.svg"))
        let faviconPng = DashboardHTTPRequest(method: "GET", target: "/favicon-32.png", path: "/favicon-32.png")
        #expect(DashboardRouteSecurity.decide(request: faviconPng, expectedOrigin: "") == .asset("favicon-32.png"))
        let appleTouch = DashboardHTTPRequest(method: "GET", target: "/apple-touch-icon.png", path: "/apple-touch-icon.png")
        #expect(DashboardRouteSecurity.decide(request: appleTouch, expectedOrigin: "") == .asset("apple-touch-icon.png"))
        let traversal = DashboardHTTPRequest(method: "GET", target: "/../pet.json", path: "/../pet.json")
        #expect(DashboardRouteSecurity.decide(request: traversal, expectedOrigin: "") == .notFound)
        let secret = DashboardHTTPRequest(method: "GET", target: "/secret.txt", path: "/secret.txt")
        #expect(DashboardRouteSecurity.decide(request: secret, expectedOrigin: "") == .notFound)
        let bundledAsset = DashboardHTTPRequest(method: "GET", target: "/assets/app-abc.js", path: "/assets/app-abc.js")
        #expect(DashboardRouteSecurity.decide(request: bundledAsset, expectedOrigin: "") == .asset("assets/app-abc.js"))
    }
}
