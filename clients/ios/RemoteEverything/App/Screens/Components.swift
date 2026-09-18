import SwiftUI

/// The small pieces every screen is made of. They exist so that a radius, a
/// hairline or a badge colour is spelled once.

/// A light banner at the top of a screen: the "轻提示" of ui-contract §3.
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        HStack(alignment: .firstTextBaseline, spacing: Theme.gapS) {
            Text(NoticeText.text(for: notice))
                .font(Theme.body)
                .foregroundStyle(NoticeText.usesErrorColor(notice) ? theme.danger : theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Theme.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Theme.gapM)
        .padding(.vertical, Theme.gapS + 2)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08), radius: 12, y: 8)
        .padding(.horizontal, Theme.gapM)
    }
}

/// Text in a semantic colour over the same colour at 12%/20% — the badge rule of
/// style.md §2.
struct StatusBadge: View {
    let text: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.gapS)
            .padding(.vertical, 3)
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

/// An application's emoji over its own accent, as a 12-point rounded square.
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

/// The 0.5 pt line that separates rows, instead of a shadow.
struct Hairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Theme(colorScheme).hairline)
            .frame(height: Theme.hairlineWidth)
    }
}

/// A thin line that means "working", never a gesture indicator (pitfalls §5).
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

/// S0's shape: one sentence about what is going on, one about what to do, and
/// one button.
struct EmptyStateView: View {
    let title: String
    let body: String
    let actionTitle: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        VStack(spacing: Theme.gapM) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.tint(theme.accent))
                .frame(width: 64, height: 64)
                .overlay(Text("📦").font(.system(size: 28)))
                .padding(.bottom, Theme.gapS)
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(body)
                .font(Theme.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle)
                    .font(Theme.body)
                    .foregroundStyle(theme.accentOnBg)
                    .padding(.horizontal, Theme.gapL)
                    .padding(.vertical, Theme.gapS + 4)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
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
    let body: String?
    let actionTitle: String?
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        VStack(spacing: Theme.gapS) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let body {
                Text(body)
                    .font(Theme.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.body)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Theme.gapL)
                        .padding(.vertical, Theme.gapS)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.gapM)
            }
        }
        .padding(Theme.gapXL)
        .frame(maxWidth: Theme.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
