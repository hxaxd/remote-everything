import Foundation

/// How one application's web host holds the screen (S4's panel).
enum WebOrientation: String, Codable, CaseIterable {
    case system
    case portrait
    case landscape
}

/// Which user agent one application's web host introduces itself with.
enum WebUserAgent: String, Codable, CaseIterable {
    case mobile
    case desktop
}

/// What the web host remembers for one application, keyed by `nodeID/appID`:
/// the two choices on the panel, kept across visits. Defaults are what an
/// application gets until its panel is touched — the system decides the
/// orientation, and the page sees the mobile user agent.
struct WebAppPrefs: Codable, Equatable {
    var orientation: WebOrientation = .system
    var userAgent: WebUserAgent = .mobile
}
