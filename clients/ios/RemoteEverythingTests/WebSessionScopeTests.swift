import XCTest
import WebKit
@testable import RemoteEverything

final class WebSessionScopeTests: XCTestCase {
    private struct ScopeCase: Decodable {
        let gatewayOrigin: String
        let appKey: String
        let profile: String
        let uuid: String
    }

    func testSharedScopeFixtures() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("clients/behavior/fixtures/web-session-scope.json"))
        let cases = try JSONDecoder().decode([ScopeCase].self, from: data)
        for item in cases {
            XCTAssertEqual(WebSessionScope.profileName(gatewayOrigin: item.gatewayOrigin, appKey: item.appKey), item.profile)
            XCTAssertEqual(WebSessionScope.identifier(gatewayOrigin: item.gatewayOrigin, appKey: item.appKey).uuidString.lowercased(), item.uuid)
        }
        XCTAssertEqual(Set(cases.map { $0.profile }).count, cases.count)
    }

    @MainActor
    func testSameHostCookiesStayInTheirPersistentStore() async throws {
        let idA = UUID(), idB = UUID()
        let a = WKWebsiteDataStore(forIdentifier: idA)
        let b = WKWebsiteDataStore(forIdentifier: idB)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "session", .value: "app-a"
        ]))
        await a.httpCookieStore.setCookie(cookie)
        let parentCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".gateway.example", .path: "/", .name: "parent", .value: "private-a"
        ]))
        await a.httpCookieStore.setCookie(parentCookie)
        let bCookies = await b.httpCookieStore.allCookies()
        XCTAssertFalse(bCookies.contains { $0.name == "session" || $0.name == "parent" })
        let reopened = WKWebsiteDataStore(forIdentifier: idA)
        let aCookies = await reopened.httpCookieStore.allCookies()
        XCTAssertEqual(aCookies.first { $0.name == "session" }?.value, "app-a")
        await a.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await b.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
