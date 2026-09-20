import XCTest
@testable import RemoteEverything

/// The behaviour all three clients share, asserted against the fixtures in
/// `clients/behavior`: the same refusal is the same name, the same two gateways
/// are one row, the same paths choose the same one, and the same catalog answer
/// is the same screen. A client that stops agreeing with these fails here —
/// which is the only way "the three clients behave alike" stays true.
///
/// The fixtures are descriptions, not wire messages: they carry prose the
/// decoders here do not use, so they are read with `JSONSerialization`-free
/// decoding of explicitly lenient DTOs. The strictness that matters — the wire's
/// own — is asserted in `WireDecodingTests` and lives in the production
/// decoders.
final class BehaviorFixturesTests: XCTestCase {

    // MARK: - Loading

    /// This file lives at `<repo>/clients/ios/RemoteEverythingTests/`, so the
    /// fixtures are four directories up and then `clients/behavior/fixtures`.
    private static func fixturesDirectory() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        var directory = thisFile.deletingLastPathComponent()
        // RemoteEverythingTests -> ios -> clients -> the repository root.
        for _ in 0..<3 {
            directory = directory.deletingLastPathComponent()
        }
        let fixtures = directory.appendingPathComponent("clients/behavior/fixtures")
        if FileManager.default.fileExists(atPath: fixtures.path) {
            return fixtures
        }
        // A build that placed this file elsewhere: walk up from the working
        // directory looking for the same directory.
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let probe = candidate.appendingPathComponent("clients/behavior/fixtures")
            if FileManager.default.fileExists(atPath: probe.path) { return probe }
            candidate = candidate.deletingLastPathComponent()
        }
        return fixtures
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = BehaviorFixturesTests.fixturesDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A missing shared fixture must fail, never skip: skipping every
            // cross-platform test is how a wrong path turns green.
            throw NSError(
                domain: "BehaviorFixturesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture \(name) is not where this checkout keeps it (\(url.path))"]
            )
        }
        return try Data(contentsOf: url)
    }

    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: try fixtureData(name))
    }

    // MARK: - errors.json

    private struct ErrorFixture: Decodable {
        struct Case: Decodable {
            let code: String
            let key: String
        }
        let cases: [Case]
    }

    func testEveryRefusalIsTheNameTheContractGivesIt() throws {
        let fixture = try fixture(ErrorFixture.self, "errors.json")
        XCTAssertEqual(fixture.cases.count, 19)
        for entry in fixture.cases {
            guard let code = ErrorCode(rawValue: entry.code) else {
                XCTFail("fixture names a code this client does not know: \(entry.code)")
                continue
            }
            XCTAssertEqual(entry.key, MessageKeys.forError(code), "for \(entry.code)")
        }
    }

    // MARK: - nodes.json

    private struct NodesFixture: Decodable {
        struct IdentityEntry: Decodable {
            let origin: String
            let isPrivate: Bool
        }
        struct Answer: Decodable {
            let origin: String
            let ok: Bool
            let reachable: Bool
            let latencyMs: Int?
            let nodes: [NodesResponse.Node]
        }
        struct Expected: Decodable {
            struct NodeEntry: Decodable {
                let id: String
                let name: String
                let pathCount: Int
                let chosenOrigin: String
                let chosenIsPrivate: Bool
                let chosenLink: String?
            }
            let nodes: [NodeEntry]
        }
        let identities: [IdentityEntry]
        let answers: [Answer]
        let expected: Expected
    }

    func testTheSameMachineThroughTwoGatewaysIsOneRowWithTheLANPathChosen() throws {
        let fixture = try fixture(NodesFixture.self, "nodes.json")
        let identities = fixture.identities.map { entry in
            Identity(
                origin: entry.origin,
                deviceName: "phone",
                certFingerprint: String(repeating: "f", count: 64),
                credentialRef: entry.origin,
                serverPin: nil,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        let answers = fixture.answers.compactMap { answer -> NodeMerge.Answer? in
            guard let identity = identities.first(where: { $0.origin == answer.origin }) else { return nil }
            return NodeMerge.Answer(
                identity: identity,
                response: NodesResponse(ok: answer.ok, nodes: answer.nodes),
                reachable: answer.reachable,
                latencyMs: answer.latencyMs,
                checkedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let merged = NodeMerge.merge(answers)
        XCTAssertEqual(fixture.expected.nodes.count, merged.count)
        for expected in fixture.expected.nodes {
            guard let node = merged.first(where: { $0.id == expected.id }) else {
                XCTFail("node \(expected.id) is missing from the merge")
                continue
            }
            XCTAssertEqual(expected.name, node.name)
            XCTAssertEqual(expected.pathCount, node.paths.count)
            let chosen = PathSelector.choose(node.paths)
            XCTAssertEqual(expected.chosenOrigin, chosen?.origin)
            // What the link is called follows the gateway's declaration when it made
            // one: a private address can still be a path that crosses the internet.
            if let want = expected.chosenLink {
                XCTAssertEqual(want, chosen?.link.rawValue)
            }
            XCTAssertEqual(expected.chosenIsPrivate, chosen?.isPrivate)
        }
    }

    // MARK: - paths.json

    private struct PathsFixture: Decodable {
        struct Case: Decodable {
            struct PathEntry: Decodable {
                let origin: String
                let reachable: Bool?
                let latencyMs: Int?
                let isPrivate: Bool
            }
            let name: String
            let paths: [PathEntry]
            let chosen: String?
        }
        let cases: [Case]
    }

    func testTheChosenPathIsTheSameEverywhere() throws {
        let fixture = try fixture(PathsFixture.self, "paths.json")
        XCTAssertFalse(fixture.cases.isEmpty)
        for entry in fixture.cases {
            let paths = entry.paths.map { path in
                Path(
                    origin: path.origin,
                    reachable: path.reachable,
                    latencyMs: path.latencyMs,
                    isPrivate: path.isPrivate,
                    lastCheckedAt: nil
                )
            }
            let chosen = PathSelector.choose(paths)
            if let expected = entry.chosen {
                XCTAssertEqual(expected, chosen?.origin, entry.name)
            } else {
                XCTAssertNil(chosen, entry.name)
            }
        }
    }

    // MARK: - cadence.json

    private struct CadenceFixture: Decodable {
        let nodeRefreshMs: Int
        let catalogRefreshMs: Int
        let controlPollMs: Int
        let controlPollFactor: Double
        let controlPollCeilingMs: Int
        let controlPollTimeoutMs: Int
        let approvalPollMs: Int
        let approvalPollTimeoutMs: Int
        let probeTimeoutMs: Int
        let requestTimeoutMs: Int
    }

    /// A node list refreshed every minute on one platform and every five on
    /// another is two products rather than one, so the numbers are the contract's
    /// and this client's table is asserted against them.
    func testThePatienceIsTheOneAllThreeClientsShare() throws {
        let fixture = try fixture(CadenceFixture.self, "cadence.json")
        XCTAssertEqual(fixture.nodeRefreshMs, Cadence.nodeRefreshMs, "nodeRefreshMs")
        XCTAssertEqual(fixture.catalogRefreshMs, Cadence.catalogRefreshMs, "catalogRefreshMs")
        XCTAssertEqual(fixture.controlPollMs, Cadence.controlPollMs, "controlPollMs")
        XCTAssertEqual(fixture.controlPollFactor, Cadence.controlPollFactor, accuracy: 0.0001, "controlPollFactor")
        XCTAssertEqual(fixture.controlPollCeilingMs, Cadence.controlPollCeilingMs, "controlPollCeilingMs")
        XCTAssertEqual(fixture.controlPollTimeoutMs, Cadence.controlPollTimeoutMs, "controlPollTimeoutMs")
        XCTAssertEqual(fixture.approvalPollMs, Cadence.approvalPollMs, "approvalPollMs")
        XCTAssertEqual(fixture.approvalPollTimeoutMs, Cadence.approvalPollTimeoutMs, "approvalPollTimeoutMs")
        XCTAssertEqual(fixture.probeTimeoutMs, Cadence.probeTimeoutMs, "probeTimeoutMs")
        XCTAssertEqual(fixture.requestTimeoutMs, Cadence.requestTimeoutMs, "requestTimeoutMs")
    }

    // MARK: - catalog.json

    private struct CatalogFixture: Decodable {
        struct Case: Decodable {
            struct ExpectedApp: Decodable {
                let id: String
                let key: String
                let fragment: String
            }
            let name: String
            let answer: CatalogResponse
            let screen: String
            let apps: [ExpectedApp]?
        }
        let cases: [Case]
    }

    func testACatalogAnswerIsTheScreenTheContractGivesIt() throws {
        let fixture = try fixture(CatalogFixture.self, "catalog.json")
        XCTAssertFalse(fixture.cases.isEmpty)
        for entry in fixture.cases {
            switch CatalogOutcome.forAnswer(entry.answer) {
            case .apps(let apps):
                XCTAssertEqual("apps", entry.screen, entry.name)
                let expected = entry.apps ?? []
                XCTAssertEqual(expected.count, apps.count, entry.name)
                for wanted in expected {
                    guard let app = apps.first(where: { $0.id == wanted.id }) else {
                        XCTFail("\(entry.name): app \(wanted.id) is missing")
                        continue
                    }
                    XCTAssertEqual(wanted.key, MessageKeys.forAppState(app.code), entry.name)
                    XCTAssertEqual(wanted.fragment, app.launchFragment, entry.name)
                }
            case .offline:
                XCTAssertEqual(MessageKeys.NODE_OFFLINE, entry.screen, entry.name)
            case .unauthorized:
                XCTAssertEqual(MessageKeys.ERROR_NODE_GONE, entry.screen, entry.name)
            case .gatewayTrouble:
                XCTAssertEqual(MessageKeys.PAIR_GATEWAY_TROUBLE, entry.screen, entry.name)
            }
        }
    }

    /// A node's state and an application's state have names too, and the shared
    /// fixtures use them for screens and rows.
    func testTheStateNamesAreTheOnesTheFixturesUse() {
        XCTAssertEqual(MessageKeys.NODE_LAN, MessageKeys.forNodeStatus(.onlineLan))
        XCTAssertEqual(MessageKeys.NODE_TUNNEL, MessageKeys.forNodeStatus(.onlineTunnel))
        XCTAssertEqual(MessageKeys.NODE_OFFLINE, MessageKeys.forNodeStatus(.offline))
        XCTAssertEqual(MessageKeys.NODE_PENDING, MessageKeys.forNodeStatus(.pendingApproval))
        XCTAssertEqual(MessageKeys.NODE_UNKNOWN, MessageKeys.forNodeStatus(.unknown))
        XCTAssertEqual(MessageKeys.APP_READY, MessageKeys.forAppState(.ready))
        XCTAssertEqual(MessageKeys.APP_STARTING, MessageKeys.forAppState(.starting))
        XCTAssertEqual(MessageKeys.APP_STOPPING, MessageKeys.forAppState(.stopping))
        XCTAssertEqual(MessageKeys.APP_STOPPED, MessageKeys.forAppState(.stopped))
    }

    // MARK: - message-keys.json

    /// The vocabulary is the contract, and the xcstrings is how iOS renders it:
    /// the catalog's keys must be exactly the shared set, complete in both
    /// languages. (Swift cannot reflect over `MessageKeys`' static constants, so
    /// the reverse direction — every constant has an entry — is enforced by the
    /// other platforms' tests and by this one asserting the catalog has nothing
    /// the fixture does not.)
    func testTheVocabularyIsTheOneTheFixtureNames() throws {
        let canonical = try JSONDecoder().decode([String].self, from: try fixtureData("message-keys.json"))
        XCTAssertEqual(Set(canonical).count, canonical.count, "the fixture lists a key twice")

        let xcstringsURL = BehaviorFixturesTests.fixturesDirectory()
            .deletingLastPathComponent()   // fixtures -> behavior
            .deletingLastPathComponent()   // behavior -> clients
            .appendingPathComponent("ios/RemoteEverything/Resources/Localizable.xcstrings")
        let document = try JSONDecoder().decode(XCStringsCatalog.self, from: Data(contentsOf: xcstringsURL))
        XCTAssertEqual(
            Set(document.strings.keys),
            Set(canonical),
            "the xcstrings keys are not the shared vocabulary"
        )
        for key in canonical {
            let localizations = document.strings[key]?.localizations
            XCTAssertNotNil(localizations?.en?.stringUnit, "\(key) has no English translation")
            XCTAssertNotNil(localizations?.zhHans?.stringUnit, "\(key) has no Chinese translation")
        }
    }

    private struct XCStringsCatalog: Decodable {
        struct Entry: Decodable {
            struct Unit: Decodable {
                let state: String
                let value: String
            }
            struct Localizations: Decodable {
                let en: Unit?
                let zhHans: Unit?
                enum CodingKeys: String, CodingKey {
                    case en
                    case zhHans = "zh-Hans"
                }
            }
            let localizations: Localizations
        }
        let strings: [String: Entry]
    }

    /// The other direction of the test above: every constant `MessageKeys`
    /// carries must name a key the fixture has, so the client cannot drift from
    /// the vocabulary by adding, renaming or dropping a constant. Swift cannot
    /// reflect over an enum's static constants, so they are read the way this
    /// file already reads the repository — out of the source, which lives at
    /// `<repo>/clients/ios/RemoteEverything/Core/Model/MessageKeys.swift`.
    func testEveryMessageKeysConstantIsAKeyTheFixtureNames() throws {
        let canonical = try JSONDecoder().decode([String].self, from: try fixtureData("message-keys.json"))

        let sourceURL = BehaviorFixturesTests.fixturesDirectory()
            .deletingLastPathComponent()   // fixtures -> behavior
            .deletingLastPathComponent()   // behavior -> clients
            .appendingPathComponent("ios/RemoteEverything/Core/Model/MessageKeys.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            XCTFail("MessageKeys.swift is not where this checkout keeps it (\(sourceURL.path))")
            return
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"static let\s+(\w+)\s*=\s*"([^"]+)""#)
        let declarations = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { match -> (name: String, value: String)? in
                guard let name = Range(match.range(at: 1), in: source),
                      let value = Range(match.range(at: 2), in: source)
                else { return nil }
                return (String(source[name]), String(source[value]))
            }
        XCTAssertFalse(declarations.isEmpty, "no constants found in \(sourceURL.path) — did the source move?")
        XCTAssertEqual(declarations.count, Set(declarations.map { $0.name }).count, "MessageKeys declares a constant twice")

        // clients/README.md: the key set is the fixture's, exactly — the value
        // each constant carries is the key, so the two sets must be one.
        XCTAssertEqual(
            Set(declarations.map { $0.value }),
            Set(canonical),
            "MessageKeys' keys are not the shared vocabulary"
        )
    }

    // MARK: - web-app-prefs.json

    private struct WebAppPrefsFixture: Decodable {
        struct Defaults: Decodable {
            let orientation: String
            let userAgent: String
        }
        let appKey: String
        let defaults: Defaults
        let orientations: [String]
        let userAgents: [String]
    }

    /// The two choices one application's panel offers are the same two on every
    /// client, in the same order, and an application nobody has touched gets the
    /// same defaults: without this the three clients could store three different
    /// vocabularies for the same two settings.
    func testThePerApplicationWebChoicesAreTheVocabularyTheFixtureNames() throws {
        let fixture: WebAppPrefsFixture = try fixture(WebAppPrefsFixture.self, "web-app-prefs.json")
        XCTAssertEqual(fixture.orientations, WebOrientation.allCases.map { $0.rawValue })
        XCTAssertEqual(fixture.userAgents, WebUserAgent.allCases.map { $0.rawValue })
        let defaults = WebAppPrefs()
        XCTAssertEqual(fixture.defaults.orientation, defaults.orientation.rawValue)
        XCTAssertEqual(fixture.defaults.userAgent, defaults.userAgent.rawValue)
    }
}
