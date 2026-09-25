import SwiftUI

/// The small pieces every screen is made of. They exist so that a radius, a
/// badge colour or a notice is spelled once, and so the glass of one screen is
/// the glass of every screen.

/// A floating toast snackbar at the bottom of the screen: a transient notice over the page.
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        let isError = NoticeText.usesErrorColor(notice)
        HStack(spacing: Theme.gapS + 2) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(Theme.body.weight(.medium))
                .foregroundStyle(isError ? theme.danger : theme.ok)
            Text(NoticeText.text(for: notice))
                .font(Theme.body.weight(.medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Theme.gapS)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.gapL)
        .padding(.vertical, Theme.gapM - 2)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.3 : 0.8),
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12),
            radius: 16,
            x: 0,
            y: 6
        )
        .frame(maxWidth: 440)
        .padding(.horizontal, Theme.gapM)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                onDismiss()
            }
        }
    }
}

/// Frosted glass card modifier providing iOS material translucency, subtle specular border, and elevation.
struct GlassCardModifier: ViewModifier {
    var isSelected: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = Theme(colorScheme)
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.accent.opacity(0.14)
                            : (colorScheme == .dark
                                ? Color.white.opacity(0.04)
                                : Color.white.opacity(0.6))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? LinearGradient(
                                colors: [theme.accent.opacity(0.85), theme.accent.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.24 : 0.8),
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? theme.accent.opacity(colorScheme == .dark ? 0.35 : 0.18)
                    : Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: isSelected ? 14 : 10,
                x: 0,
                y: 4
            )
    }
}

extension View {
    func glassCard(isSelected: Bool = false) -> some View {
        modifier(GlassCardModifier(isSelected: isSelected))
    }
}

/// Gentle scale and opacity transition on tap, mimicking iOS system card physics.
struct GlassPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A word in its own semantic colour over a quiet glass capsule.
struct StatusBadge: View {
    let text: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.gapS + 2)
            .padding(.vertical, 4)
            .background(theme.tint(color), in: Capsule())
    }
}

/// The only thing said about which road a node is reached by.
struct PathLabel: View {
    let isPrivate: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        Text(isPrivate ? l10n(MessageKeys.NODE_LAN) : l10n(MessageKeys.NODE_TUNNEL))
            .font(Theme.caption)
            .foregroundStyle(theme.textSecondary)
    }
}

/// The ways in this phone has to one machine: a local link, a link over the
/// tunnel, or both — each a dot and a word, with the one it would actually take
/// standing out and the other left quiet. Two links is the ordinary state of a
/// phone that paired over the internet and later met the gateway at home, and
/// seeing both is how a person knows that losing one of them is not losing the
/// machine.
struct LinkDots: View {

    let paths: [Path]
    let inUse: Path?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        HStack(spacing: Theme.gapS) {
            ForEach([LinkKind.local, LinkKind.tunnel], id: \.self) { kind in
                if paths.contains(where: { $0.link == kind }) {
                    let live = inUse?.link == kind
                    HStack(spacing: 4) {
                        Circle()
                            .fill(dotColour(theme, live: live, kind: kind))
                            .frame(width: 7, height: 7)
                        Text(l10n(kind == .local ? MessageKeys.NODE_LAN : MessageKeys.NODE_TUNNEL))
                            .font(Theme.caption)
                            .foregroundStyle(dotColour(theme, live: live, kind: kind))
                    }
                }
            }
        }
    }

    private func dotColour(_ theme: Theme, live: Bool, kind: LinkKind) -> Color {
        if !live { return theme.textTertiary }
        return kind == .local ? theme.ok : theme.warn
    }
}

/// An application's emoji over its own accent, as a rounded square.
struct AppIconTile: View {
    let icon: String
    let accent: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.tint(accent ?? theme.accent))
            .frame(width: 40, height: 40)
            .overlay(
                Text(icon.isEmpty ? "📦" : icon)
                    .font(.system(size: 20))
            )
    }
}

/// A status light: a dot in the row's semantic colour.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

/// The thin line that separates rows, where a list style does not do it.
struct Hairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Theme(colorScheme).hairline.opacity(0.6))
            .frame(height: Theme.hairlineWidth)
    }
}

/// A thin line that means "working", never a gesture indicator.
struct LoadingLine: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        ProgressView()
            .progressViewStyle(.linear)
            .tint(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
    }
}

/// The empty state: what is going on, what to do, and the one button.
/// The page's own words only — no invented icon, because a state a person has
/// not met before reads better as itself than as a box with a face on it.
struct EmptyStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.gapM) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle)
                    .font(Theme.body)
            }
            .reGlassButton()
            .padding(.top, Theme.gapS)
        }
        .padding(Theme.gapXL)
        .frame(maxWidth: Theme.contentMaxWidth)
    }
}

/// A whole-page answer that is not an error: S3's offline page and S4's failure
/// page both use it.
struct MessagePage: View {
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.gapS) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.body)
                }
                .buttonStyle(.bordered)
                .padding(.top, Theme.gapM)
            }
        }
        .padding(Theme.gapXL)
        .frame(maxWidth: Theme.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
