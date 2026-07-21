import Foundation
import Observation
import UIKit

// MARK: - Types

/// A validated GitHub release used for version discovery.
struct AppRelease: Codable {
    let versionName: String
    let tagName: String
    let pageUrl: String
}

/// Update UI state. Mirrors Android's `UpdateUiState`.
enum UpdateUiState {
    case idle
    case checking
    case current(latestVersion: String, currentIsNewer: Bool)
    case available(AppRelease)
    case downloading(AppRelease, progress: Float)
    case ready(AppRelease, filePath: String)
    case error(String)
}

// MARK: - Update Protocol

/// Pure data contract for GitHub Release parsing and version comparison.
/// Mirrors Android's `UpdateProtocol`.
enum UpdateProtocol {
    static let projectUrl = "https://github.com/hxaxd/remote-everything"
    private static let versionPattern = try! Regex("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")

    /// Parse the GitHub Releases API "latest" response.
    static func parseLatestRelease(body: String) throws -> AppRelease {
        guard let data = body.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.invalidResponse
        }

        let draft = json["draft"] as? Bool ?? true
        let prerelease = json["prerelease"] as? Bool ?? true
        guard !draft && !prerelease else {
            throw UpdateError.notInstallable
        }

        guard let tag = json["tag_name"] as? String else {
            throw UpdateError.invalidResponse
        }
        let version = try canonicalVersion(tag)
        guard tag == "v\(version)" else {
            throw UpdateError.invalidTagFormat
        }

        guard let pageUrl = json["html_url"] as? String,
              pageUrl == "\(projectUrl)/releases/tag/\(tag)" else {
            throw UpdateError.invalidPageUrl
        }

        return AppRelease(
            versionName: version,
            tagName: tag,
            pageUrl: pageUrl
        )
    }

    /// Compare two semantic versions. Returns positive if left > right.
    static func compareVersions(_ left: String, _ right: String) throws -> Int {
        let a = try versionParts(left)
        let b = try versionParts(right)
        for i in a.indices {
            if a[i] < b[i] { return -1 }
            if a[i] > b[i] { return 1 }
        }
        return 0
    }

    // MARK: - Private

    private static func canonicalVersion(_ value: String) throws -> String {
        guard let match = try versionPattern.wholeMatch(in: value) else {
            throw UpdateError.invalidVersionFormat
        }
        // match.1, match.2, match.3 are the three numeric groups
        let groups = match.output
        return "\(groups[1].substring!).\(groups[2].substring!).\(groups[3].substring!)"
    }

    private static func versionParts(_ value: String) throws -> [Int64] {
        let canonical = try canonicalVersion(value)
        return try canonical.split(separator: ".").map { part in
            guard let num = Int64(part), num <= Int64(Int32.max) else {
                throw UpdateError.versionOutOfRange
            }
            return num
        }
    }

    enum UpdateError: Error, CustomStringConvertible {
        case invalidResponse
        case notInstallable
        case invalidTagFormat
        case invalidPageUrl
        case invalidVersionFormat
        case versionOutOfRange

        var description: String {
            switch self {
            case .invalidResponse: return "发布信息无效"
            case .notInstallable: return "最新发布版不可安装"
            case .invalidTagFormat: return "发布标签格式无效"
            case .invalidPageUrl: return "发布页面地址无效"
            case .invalidVersionFormat: return "版本号格式无效"
            case .versionOutOfRange: return "版本号超出范围"
            }
        }
    }
}

// MARK: - App Updater

/// Checks GitHub Releases for updates. Mirrors Android's `AppUpdater`.
/// On iOS, cannot download/install APK — only checks and directs to GitHub.
@Observable
final class AppUpdater {
    private(set) var state: UpdateUiState = .idle

    private static let latestReleaseApi = "https://api.github.com/repos/hxaxd/remote-everything/releases/latest"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.4.1"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "26"
    }

    func checkForUpdates() async {
        state = .checking

        do {
            let body = try await downloadText(url: Self.latestReleaseApi, apiRequest: true)
            let release = try UpdateProtocol.parseLatestRelease(body: body)

            let comparison = try UpdateProtocol.compareVersions(release.versionName, currentVersion)
            if comparison > 0 {
                state = .available(release)
            } else {
                state = .current(latestVersion: release.versionName, currentIsNewer: comparison < 0)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func openGitHubRelease(_ release: AppRelease) {
        if let url = URL(string: release.pageUrl) {
            UIApplication.shared.open(url)
        }
    }

    func openGitHubProject() {
        if let url = URL(string: UpdateProtocol.projectUrl) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Private

    private func downloadText(url: String, apiRequest: Bool) async throws -> String {
        guard let requestUrl = URL(string: url) else {
            throw UpdateProtocol.UpdateError.invalidResponse
        }

        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 30
        request.setValue(
            apiRequest ? "application/vnd.github+json" : "application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("RemoteEverything/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if apiRequest {
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateProtocol.UpdateError.invalidResponse
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateProtocol.UpdateError.invalidResponse
        }

        return text
    }
}
