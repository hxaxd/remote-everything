import SwiftUI

/// The panel S4's back gesture opens: how the screen is held, how the page
/// introduces itself, a reload, and the way out. It replaces the bar that used
/// to sit over the page — the screen belongs to the page now, and everything
/// the bar carried (a reload and a close, and nothing else) is here, as two
/// settings rows and two actions.
struct WebPanelView: View {

    let theme: Theme
    let prefs: WebAppPrefs
    let onOrientation: (WebOrientation) -> Void
    let onUserAgent: (WebUserAgent) -> Void
    let onRefresh: () -> Void
    let onExit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: Theme.gapM) {
                settingRow(
                    l10n(MessageKeys.WEB_ORIENTATION),
                    options: [
                        (l10n(MessageKeys.WEB_ORIENTATION_SYSTEM), WebOrientation.system),
                        (l10n(MessageKeys.WEB_ORIENTATION_PORTRAIT), .portrait),
                        (l10n(MessageKeys.WEB_ORIENTATION_LANDSCAPE), .landscape),
                    ],
                    selected: prefs.orientation,
                    onSelect: onOrientation
                )
                settingRow(
                    l10n(MessageKeys.WEB_USER_AGENT),
                    options: [
                        (l10n(MessageKeys.WEB_USER_AGENT_MOBILE), WebUserAgent.mobile),
                        (l10n(MessageKeys.WEB_USER_AGENT_DESKTOP), .desktop),
                    ],
                    selected: prefs.userAgent,
                    onSelect: onUserAgent
                )
                Hairline().padding(.top, Theme.gapS)
                actionRow("arrow.clockwise", l10n(MessageKeys.WEB_REFRESH), action: onRefresh)
                actionRow("xmark", l10n(MessageKeys.WEB_EXIT), action: onExit)
            }
            .padding(Theme.gapM)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.bgElevated)
            )
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(10)
        }
    }

    private func settingRow<T: Equatable>(
        _ label: String,
        options: [(String, T)],
        selected: T,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: Theme.gapM) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    let title = options[index].0
                    let value = options[index].1
                    let chosen = value == selected
                    Text(title)
                        .font(Theme.footnote)
                        .foregroundStyle(chosen ? theme.accent : theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(chosen ? theme.tint(theme.accent) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { if !chosen { onSelect(value) } }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.bg)
            )
        }
    }

    private func actionRow(_ glyph: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.gapS) {
                Image(systemName: glyph)
                    .font(Theme.body)
                    .frame(width: 24, alignment: .leading)
                Text(label)
                    .font(Theme.headline)
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}
