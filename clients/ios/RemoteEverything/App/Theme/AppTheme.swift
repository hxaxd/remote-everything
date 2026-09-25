import SwiftUI

/// The visual tokens all three clients share, in Swift.
///
/// The semantic colours — the accent, and the four state colours — are the same
/// everywhere, with a light and a dark value. The backgrounds lean on the
/// system's own material so the chrome is Liquid Glass on iOS 26+ and the
/// system's grouped background before it: an app that paints its own grey sits
/// on top of the platform instead of inside it.
struct Theme {

    init(_ scheme: ColorScheme) {
        // The colours below resolve against the view's trait collection, not the
        // SwiftUI colorScheme environment, on purpose: a presented sheet's trait
        // collection follows the appearance change immediately, while its
        // environment value can lag a beat — which is how a sheet's background
        // switched while its text stayed behind. Everything here is a dynamic
        // system colour or a dynamic UIColor, so the sheet follows as one.
        _ = scheme
    }

    // MARK: - Colours

    /// The system's grouped background: the surface the whole screen sits on.
    var bg: Color { Color(.systemGroupedBackground) }
    /// The system's card background, for anything a hairline used to separate.
    var bgElevated: Color { Color(.secondarySystemGroupedBackground) }
    var textPrimary: Color { Color(.label) }
    var textSecondary: Color { Color(.secondaryLabel) }
    var textTertiary: Color { Color(.tertiaryLabel) }
    var hairline: Color { Color(.separator) }
    var accent: Color { Theme.dynamic(0x3B6EA5, 0x6E97C4) }
    var accentOnBg: Color { Theme.dynamic(0xFFFFFF, 0x0F1B28) }
    var ok: Color { Theme.dynamic(0x3D8B6D, 0x63A98B) }
    var warn: Color { Theme.dynamic(0xB08A3E, 0xC9A55C) }
    var danger: Color { Theme.dynamic(0xB05454, 0xC47A7A) }
    /// Not being online is not an error: it is grey, in both modes.
    var offline: Color { Theme.dynamic(0x9C9C9C, 0x6E6E6E) }

    /// The tint a badge or an icon tile uses behind its own colour: a quiet
    /// wash in both modes, resolved with the colour itself.
    func tint(_ colour: Color) -> Color {
        colour.opacity(0.16)
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

    /// A colour pair chosen by the trait that is actually rendering — the
    /// light value in light, the dark value in dark, re-resolved as the
    /// appearance changes instead of captured when the view was built.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: - Shapes

    static let radiusControl: CGFloat = 12
    static let radiusCard: CGFloat = 20
    static let gapS: CGFloat = 8
    static let gapM: CGFloat = 16
    static let gapL: CGFloat = 24
    static let gapXL: CGFloat = 32
    static let nodeRowHeight: CGFloat = 64
    static let appRowHeight: CGFloat = 76
    static let hairlineWidth: CGFloat = 0.5
    /// The width at which S1 and S3 share the screen.
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

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Liquid Glass, applied where the platform has it and read as a quiet material
/// where it does not. The app's floor is iOS 17, so every call goes through one
/// of these helpers instead of the raw `glassEffect`, which is iOS 26 only.
///
/// The helpers also stand down under the unit-test host: the test bundle runs
/// the real app, and Liquid Glass rendering is a runtime feature that has no
/// business being on during a test — it has been known to stall the host.
enum AppEnvironment {
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

extension View {

    /// A glass card: on iOS 26+ the platform's own Liquid Glass in the given
    /// shape; before that, a translucent material in the same shape.
    @ViewBuilder
    func reGlassCard(cornerRadius: CGFloat = Theme.radiusCard) -> some View {
        if #available(iOS 26.0, *), !AppEnvironment.isRunningTests {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A glass container, so nested glass effects composite into one surface.
    /// A no-op where the platform does not have it.
    @ViewBuilder
    func reGlassContainer() -> some View {
        if #available(iOS 26.0, *), !AppEnvironment.isRunningTests {
            GlassEffectContainer { self }
        } else {
            self
        }
    }

    /// A borderless button that reads as glass: the system's own on iOS 26+,
    /// a quiet filled capsule before that.
    @ViewBuilder
    func reGlassButton() -> some View {
        if #available(iOS 26.0, *), !AppEnvironment.isRunningTests {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
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
