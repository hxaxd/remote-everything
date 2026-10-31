import SwiftUI

/// The visual tokens all three clients share, in Swift.
///
/// Only three radii exist, only the named spacing steps, and one colour set for
/// light and one for dark. A screen that needs a fourth radius wants a different
/// design, not a new token.
struct Theme {

    let scheme: ColorScheme

    init(_ scheme: ColorScheme) {
        self.scheme = scheme
    }

    private var isDark: Bool { scheme == .dark }

    // MARK: - Colours

    var bg: Color { Theme.token(0xFAFAFA, 0x141414, isDark) }
    var bgElevated: Color { Theme.token(0xFFFFFF, 0x1E1E1E, isDark) }
    var textPrimary: Color { Theme.token(0x1A1A1A, 0xE8E8E8, isDark) }
    var textSecondary: Color { Theme.token(0x6B6B6B, 0xA0A0A0, isDark) }
    var textTertiary: Color { Theme.token(0x9C9C9C, 0x6E6E6E, isDark) }
    var hairline: Color { Theme.token(0xE5E5E5, 0x2E2E2E, isDark) }
    var accent: Color { Theme.token(0x3B6EA5, 0x6E97C4, isDark) }
    var accentOnBg: Color { Theme.token(0xFFFFFF, 0x0F1B28, isDark) }
    var ok: Color { Theme.token(0x3D8B6D, 0x63A98B, isDark) }
    var warn: Color { Theme.token(0xB08A3E, 0xC9A55C, isDark) }
    var danger: Color { Theme.token(0xB05454, 0xC47A7A, isDark) }
    /// Not being online is not an error: it is grey, in both modes.
    var offline: Color { Theme.token(0x9C9C9C, 0x6E6E6E, isDark) }

    /// The tint a badge or an icon tile uses behind its own colour: 12% in light,
    /// 20% in dark.
    func tint(_ colour: Color) -> Color {
        colour.opacity(isDark ? 0.20 : 0.12)
    }

    /// The accent a node status is drawn in.
    func color(for status: NodeStatus) -> Color {
        switch status {
        case .onlineLan, .onlineTunnel: return ok
        case .pendingApproval: return warn
        case .offline, .unknown: return offline
        }
    }

    /// The accent an application state is drawn in.
    func color(for state: AppState) -> Color {
        switch state {
        case .ready: return ok
        case .starting, .stopping: return warn
        case .stopped: return offline
        }
    }

    // MARK: - Shapes

    static let radiusControl: CGFloat = 10
    static let gapS: CGFloat = 8
    static let gapM: CGFloat = 16
    static let gapL: CGFloat = 24
    static let gapXL: CGFloat = 32
    static let nodeRowHeight: CGFloat = 64
    static let appRowHeight: CGFloat = 72
    static let hairlineWidth: CGFloat = 0.5
    /// The width at which S1 and S3 share the screen (ui-contract §6).
    static let wideLayoutShortSide: CGFloat = 840
    /// Content stops growing past this on a wide screen.
    static let contentMaxWidth: CGFloat = 720

    // MARK: - Type

    static let headline = Font.system(.headline, weight: .medium)
    static let body = Font.system(.subheadline)
    static let caption = Font.system(.footnote)
    static let footnote = Font.system(.caption)
    static let mono = Font.system(.footnote, design: .monospaced)

    /// A colour pair from the palette: the light value and the dark one.
    static func token(_ light: UInt32, _ dark: UInt32, _ isDark: Bool) -> Color {
        Color(hex: isDark ? dark : light)
    }
}

extension Color {
    /// A token colour, or the accent a gateway sent for one application.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// `#RRGGBB`, the shape the wire promises for an accent.
    init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7 else { return nil }
        guard let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// A fingerprint as an operator reads it: lowercased, grouped every eight
/// characters, in a monospaced face.
func groupedFingerprint(_ fingerprint: String) -> String {
    let value = fingerprint.lowercased()
    var groups: [String] = []
    var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 8, limitedBy: value.endIndex) ?? value.endIndex
        groups.append(String(value[index..<end]))
        index = end
    }
    return groups.joined(separator: " ")
}
