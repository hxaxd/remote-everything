import SwiftUI

/// S3: what one node runs, and the buttons that start and stop it.
struct NodeScreen: View {

    let nodeID: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        let node = model.node(withID: nodeID)
        VStack(spacing: 0) {
            Hairline()
            page(theme, node: node)
        }
        .background(theme.bg)
        .navigationTitle(node?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Under its own name, whose screen this is, and which way the phone is
            // getting there.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(node?.name ?? "")
                        .font(Theme.headline)
                        .foregroundStyle(theme.textPrimary)
                    // Under its own name, whose screen this is, and which way the
                    // phone is getting there: the path, or the state's own name
                    // when there is no path to describe (Android's NodeBar).
                    if let node = model.node(withID: nodeID) {
                        Text(pathHintOrStatus(node))
                            .font(Theme.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .task {
            model.beginCatalogPolling(nodeID: nodeID)
            await model.loadCatalog(nodeID: nodeID)
        }
        .onDisappear {
            model.endCatalogPolling()
        }
    }

    /// Asking again means asking now: the node list is read again — the paths it
    /// carries are what a catalog is fetched through — and this node's catalog
    /// with it (Android retryNode).
    private func retry() {
        Task {
            await model.refreshNodes()
            await model.loadCatalog(nodeID: nodeID)
        }
    }

    @ViewBuilder
    private func page(_ theme: Theme, node: Node?) -> some View {
        if let node {
            switch model.catalogs[nodeID] {
            case .none, .some(.loading):
                VStack {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.ready(let apps)):
                if apps.isEmpty {
                    MessagePage(
                        title: l10n(MessageKeys.APPS_EMPTY_TITLE),
                        message: l10n(MessageKeys.APPS_EMPTY_BODY),
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: Theme.gapM) {
                            ForEach(apps) { app in
                                ApplicationRow(
                                    app: app,
                                    onOpen: { open(app) },
                                    onStart: { model.startApplication(nodeID: nodeID, appID: app.id) },
                                    onStop: { model.stopApplication(nodeID: nodeID, appID: app.id) }
                                )
                            }
                        }
                        .padding(.horizontal, Theme.gapM)
                        .padding(.vertical, Theme.gapM)
                    }
                    .refreshable { await model.loadCatalog(nodeID: nodeID) }
                }
            case .some(.offline):
                MessagePage(
                    title: l10n(MessageKeys.NODE_OFFLINE_TITLE),
                    message: l10n(MessageKeys.NODE_OFFLINE_BODY),
                    actionTitle: l10n(MessageKeys.ACTION_RETRY),
                    action: retry
                )
            case .some(.unauthorized):
                MessagePage(
                    title: l10n(MessageKeys.ERROR_NODE_GONE),
                    message: l10n(MessageKeys.ERROR_NODE_GONE_BODY),
                    actionTitle: l10n(MessageKeys.ACTION_BACK_TO_NODES),
                    action: {
                        model.selectedNodeID = nil
                        model.path.removeAll()
                        Task { await model.refreshNodes() }
                    }
                )
            case .some(.gatewayTrouble):
                // The gateway answered and its answer is a refusal: the same
                // words every client says here, and the retry that asks again.
                MessagePage(
                    title: l10n(MessageKeys.PAIR_GATEWAY_TROUBLE),
                    message: nil,
                    actionTitle: l10n(MessageKeys.ACTION_RETRY),
                    action: retry
                )
            }
        } else {
            MessagePage(
                title: l10n(MessageKeys.ERROR_NODE_GONE),
                message: l10n(MessageKeys.ERROR_NODE_GONE_BODY),
                actionTitle: l10n(MessageKeys.ACTION_BACK_TO_NODES),
                action: {
                    model.selectedNodeID = nil
                    model.path.removeAll()
                    Task { await model.refreshNodes() }
                }
            )
        }
    }

    /// The one-line answer under a node's name: the road in use, or the state's
    /// own name when nothing is answering — the fallback Android's NodeBar uses.
    private func pathHintOrStatus(_ node: Node) -> String {
        currentPathHint(model.preferredPath(for: node))
            ?? l10n(MessageKeys.forNodeStatus(model.status(of: node)))
    }

    /// Tapping an application opens it. A stopped one is opened as it is — the
    /// start is its own button — exactly as Android opens a stopped-but-enabled
    /// app; only one that cannot be started at all is left alone.
    private func open(_ app: AppInfo) {
        switch app.code {
        case .ready, .starting:
            model.path.append(.application(nodeID: nodeID, appID: app.id))
        case .stopped where app.enabled:
            model.path.append(.application(nodeID: nodeID, appID: app.id))
        case .stopped, .stopping:
            break
        }
    }
}

private struct ApplicationRow: View {

    let app: AppInfo
    let onOpen: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        HStack(spacing: Theme.gapM) {
            Button(action: onOpen) {
                HStack(spacing: Theme.gapM) {
                    AppIconTile(icon: app.icon, accent: Color(hexString: app.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(Theme.headline)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if !app.description.isEmpty {
                            Text(app.description)
                                .font(Theme.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.gapS)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressButtonStyle())

            StatusBadge(text: stateText, color: theme.color(for: app.code))

            if app.code == .starting || app.code == .stopping {
                ProgressView()
                    .frame(width: 28)
            } else {
                Button(action: app.code == .stopped ? onStart : onStop) {
                    Text(app.code == .stopped ? l10n(MessageKeys.ACTION_START) : l10n(MessageKeys.ACTION_STOP))
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(app.code == .stopped ? theme.accentOnBg : theme.textPrimary)
                        .padding(.horizontal, Theme.gapM - 2)
                        .padding(.vertical, Theme.gapS - 2)
                        .background(
                            app.code == .stopped
                                ? AnyShapeStyle(theme.accent)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    app.code == .stopped
                                        ? Color.clear
                                        : Color.white.opacity(colorScheme == .dark ? 0.2 : 0.4),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.gapL)
        .padding(.vertical, Theme.gapM)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var stateText: String {
        l10n(MessageKeys.forAppState(app.code))
    }
}

/// The one-line answer to "which way am I going in": local link or tunnel, said
/// with the same words the row uses. A machine nothing answers for has no path to
/// describe, and its own screen already says so.
private func currentPathHint(_ path: Path?) -> String? {
    switch path?.link {
    case .local: return l10n(MessageKeys.NODE_CURRENT_LAN)
    case .tunnel: return l10n(MessageKeys.NODE_CURRENT_TUNNEL)
    case .none: return nil
    }
}
