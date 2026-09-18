import Foundation

/// What this build says about itself. The version and the build number come from
/// the bundle's Info.plist, which clients/release.json is the source of; the
/// protocol version is the one this source speaks.
enum AppVersion {
    static let protocolVersion = 1

    static var versionName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildNumber: Int {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return 0 }
        return Int(raw) ?? 0
    }
}

/// What checking for updates found.
enum UpdateResult: Equatable {
    case upToDate
    case available(versionName: String, buildNumber: Int)
    /// The protocol itself changed: upgrading is not enough, pairing again is
    /// part of it. There is no negotiation and no compatibility path.
    case protocolChanged(protocolVersion: Int)
    case unreachable

    var isProtocolChange: Bool {
        if case .protocolChanged = self { return true }
        return false
    }
}

/// Checking for a newer release. Deliberately decoupled from any gateway: a
/// device that has never paired can still check, and a gateway being down must
/// not look like a version problem.
final class UpdateChecker {

    /// The published release manifest — a fixed address, not a gateway path.
    static let manifestURLString = "https://raw.githubusercontent.com/hxaxd/remote-everything/main/clients/release.json"

    private let session: URLSession
    private let manifestURLString: String

    init(session: URLSession? = nil, manifestURLString: String = UpdateChecker.manifestURLString) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // A manifest is not a probe and not a gateway: it gets the same time
            // as any other request this client makes, `Cadence`'s, and no more.
            configuration.timeoutIntervalForRequest = Cadence.requestTimeout
            configuration.timeoutIntervalForResource = Cadence.requestTimeout * 2
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.manifestURLString = manifestURLString
    }

    func check(currentBuildNumber: Int, currentProtocolVersion: Int) async -> UpdateResult {
        guard let url = URL(string: manifestURLString) else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = Cadence.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return .unreachable }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .unreachable }
        guard let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else { return .unreachable }

        if manifest.protocolVersion != currentProtocolVersion {
            return .protocolChanged(protocolVersion: manifest.protocolVersion)
        }
        if manifest.buildNumber > currentBuildNumber {
            return .available(versionName: manifest.versionName, buildNumber: manifest.buildNumber)
        }
        return .upToDate
    }
}
