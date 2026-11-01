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
        .glassPanel(cornerRadius: Theme.radiusControl)
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

/// The ways in this phone has to one machine: a local link, a link over the tunnel,
/// or both — each a dot and a word, with the one it would actually take standing
/// out and the other left quiet. Two links is the ordinary state of a phone that
/// paired over the internet and later met the gateway at home, and seeing both is
/// how a person knows that losing one of them is not losing the machine.
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
    // Not `body`: a stored property of a View may not be named for the one the
    // protocol already asks for.
    let message: String
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
            Text(message)
                .font(Theme.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle)
            }
            .buttonStyle(ActionButtonStyle(height: 44))
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        VStack(spacing: Theme.gapS) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
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

/// A surface that carries iOS 26's glass where it exists, and a material of the
/// same weight where it does not, so cards and notices keep one visual language
/// across the versions this app supports.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color?
    /// `glassEffect` draws its own highlight edge, which on light surfaces reads
    /// as a white frame. Controls that want a calm surface ask for no stroke and
    /// get the material without the highlight.
    var stroked: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *), stroked {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if let tint { shape.fill(tint) }
                        }
                        .overlay {
                            // A glass surface catches light. The highlight is a
                            // gradient inside the shape, not an edge stroke, so
                            // it reads as a surface instead of a white frame.
                            shape.fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.24), Color.white.opacity(0.04), Color.black.opacity(0.03)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .mask(shape)
                        }
                }
                .overlay {
                    if stroked {
                        shape.strokeBorder(Theme(colorScheme).hairline, lineWidth: Theme.hairlineWidth)
                    }
                }
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14, tint: Color? = nil, stroked: Bool = true) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint, stroked: stroked))
    }
}

/// Puts the appearance on the window instead of asking each view. SwiftUI's
/// preferredColorScheme leaves the sheet and parts of the chrome a beat behind,
/// and reverting it to nil (follow the system) does not always take; the window
/// switches everything at once, and `unspecified` is the system again.
struct WindowInterfaceStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { view.window?.overrideUserInterfaceStyle = style }
    }
}

private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Pull to refresh, with the indicator behind the content instead of floating
/// over it, and a shorter pull than the system asks for. The toolbar's refresh
/// goes through the same state, so a tap plays the same animation a pull does.
struct PullRefresh<Content: View>: View {

    let isRefreshing: Bool
    let onRefresh: () -> Void
    var threshold: CGFloat = 44
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var pull: CGFloat = 0
    @State private var armed = false

    private let space = "pull.refresh"

    var body: some View {
        let theme = Theme(colorScheme)
        ZStack(alignment: .top) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.accent)
                .frame(maxWidth: .infinity)
                .frame(height: isRefreshing ? threshold : pull)
                .opacity(isRefreshing || pull > 0 ? 1 : 0)
                .scaleEffect(min(1, (isRefreshing ? threshold : pull) / threshold))

            scroll
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isRefreshing)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: pull)
        .onChange(of: isRefreshing) { _, refreshing in
            // The pull is frozen while the refresh runs; if a scroll happens in
            // that window the frozen value would outlive the refresh and leave
            // the indicator standing. The end of a refresh is a clean slate.
            if !refreshing {
                pull = 0
                armed = false
            }
        }
    }

    @ViewBuilder
    private var scroll: some View {
        if #available(iOS 18.0, *) {
            base
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                } action: { _, value in
                    guard !isRefreshing else { return }
                    pull = value
                    armed = value >= threshold
                }
                .simultaneousGesture(
                    DragGesture().onEnded { _ in
                        if armed && !isRefreshing { onRefresh() }
                        armed = false
                    }
                )
        } else {
            base
                .simultaneousGesture(
                    DragGesture().onEnded { _ in
                        if armed && !isRefreshing { onRefresh() }
                        armed = false
                    }
                )
                .onPreferenceChange(PullOffsetKey.self) { value in
                    guard !isRefreshing else { return }
                    pull = max(0, value)
                    armed = pull >= threshold
                }
        }
    }

    private var base: some View {
        ScrollView {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Color.clear.preference(key: PullOffsetKey.self, value: geo.frame(in: .named(space)).minY)
                }
                .frame(height: 0)
                Color.clear.frame(height: isRefreshing ? threshold : 0)
                content()
            }
        }
        .coordinateSpace(name: space)
        .scrollBounceBehavior(.always, axes: .vertical)
        .background(Color.clear)
    }
}

/// The one action button: a glass surface tinted with the accent, the label in
/// the primary ink. A solid accent fill is the system's blue by another name and
/// reads as a different product next to the scan action.
struct ActionButtonStyle: ButtonStyle {
    var height: CGFloat = 48

    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme(colorScheme)
        configuration.label
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .glassPanel(cornerRadius: Theme.radiusControl, tint: theme.accent.opacity(0.24))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
