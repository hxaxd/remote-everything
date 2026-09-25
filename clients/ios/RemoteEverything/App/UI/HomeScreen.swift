import SwiftUI

/// S0 and S1: the empty state, and the merged list of every gateway's nodes.
struct HomeScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.reWideLayout) private var isWide

    var body: some View {
        let theme = Theme(colorScheme)
        content(theme)
            .background(theme.bg)
            .navigationTitle(l10n(MessageKeys.APP_NAME))
            // An inline title sits at the top, aligned with the bar's buttons,
            // the way the node screen's does. A large title would hang lower
            // than the buttons and only collapse after a long scroll — a large
            // title that takes a head of space to earn its smallness.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        addNode()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(l10n(MessageKeys.ACTION_ADD_NODE))
                    .accessibilityIdentifier("home.add")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // Beside the list (a wide screen) settings are the pane; on a
                        // phone they are a pushed page — a sheet cannot be relied on
                        // to follow an appearance change.
                        if isWide {
                            model.setPane(.settings)
                        } else {
                            model.pushSettings()
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(l10n(MessageKeys.SETTINGS_TITLE))
                }
            }
    }

    /// Adding a node is a pane beside the list on a wide screen and a pushed
    /// page on a phone — the same two homes Android gives it.
    private func addNode() {
        if isWide {
            model.setPane(.addNode)
        } else {
            model.beginAddNode()
        }
    }

    @ViewBuilder
    private func content(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            if let staged = model.stagedSetups.first {
                HStack(spacing: Theme.gapM) {
                    StatusBadge(text: l10n(MessageKeys.NODE_PENDING), color: theme.warn)
                    Text(staged.nodeName)
                        .font(Theme.headline)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task { await model.resumeStagedSetups() }
                    } label: {
                        Text(l10n(MessageKeys.ACTION_RETRY))
                            .font(Theme.caption)
                            .foregroundStyle(theme.accentOnBg)
                            .padding(.horizontal, Theme.gapM)
                            .padding(.vertical, 6)
                            .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.gapL)
                .padding(.vertical, Theme.gapM)
                .glassCard()
                .padding(.horizontal, Theme.gapM)
                .padding(.top, Theme.gapS)
            }
            if model.identities.isEmpty && model.stagedSetups.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: l10n(MessageKeys.EMPTY_TITLE),
                        message: l10n(MessageKeys.EMPTY_BODY),
                        actionTitle: l10n(MessageKeys.ACTION_ADD_NODE),
                        action: addNode
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.gapXL * 2)
                }
                .refreshable { await model.refreshNodes() }
            } else if model.nodes.isEmpty {
                // Paired, but nothing to show: the nodes were taken away on the
                // gateway's side. Same words as S0, and settings stay reachable.
                ScrollView {
                    EmptyStateView(
                        title: l10n(MessageKeys.EMPTY_TITLE),
                        message: l10n(MessageKeys.EMPTY_BODY),
                        actionTitle: l10n(MessageKeys.ACTION_ADD_NODE),
                        action: addNode
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.gapXL * 2)
                }
                .refreshable { await model.refreshNodes() }
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.gapM) {
                        ForEach(model.nodes) { node in
                            let isSelected = isWide && model.selectedNodeID == node.id
                            Button {
                                open(node)
                            } label: {
                                NodeRow(
                                    node: node,
                                    status: model.status(of: node),
                                    inUse: model.status(of: node).isOnline ? model.preferredPath(for: node) : nil,
                                    isSelected: isSelected
                                )
                            }
                            .buttonStyle(GlassPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.gapM)
                    .padding(.vertical, Theme.gapM)
                }
                .refreshable { await model.refreshNodes() }
            }
        }
    }

    private func open(_ node: Node) {
        if model.status(of: node) == .pendingApproval {
            // Waiting for the operator: there is nothing to show yet, and asking
            // again is what pull-to-refresh does.
            return
        }
        if isWide {
            // Opening a node is choosing it: a pane open beside the list gives
            // way, the way Android's onSelect clears its pane.
            model.setPane(nil)
            model.selectedNodeID = node.id
            model.path.removeAll()
        } else {
            model.path.append(.node(node.id))
        }
    }
}

/// One node row: name, state, and — only when it is online — the road it is
/// reached by.
private struct NodeRow: View {
    let node: Node
    let status: NodeStatus
    let inUse: Path?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        HStack(spacing: Theme.gapM) {
            ZStack {
                Circle()
                    .fill(theme.color(for: status).opacity(0.18))
                    .frame(width: 22, height: 22)
                StatusDot(color: theme.color(for: status))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(Theme.headline)
                    .foregroundStyle(isSelected ? theme.accent : (status == .offline || status == .unknown ? theme.textSecondary : theme.textPrimary))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.gapS)
            // Which ways in this phone has, and which one it would take.
            if status == .pendingApproval {
                StatusBadge(text: l10n(MessageKeys.forNodeStatus(status)), color: theme.color(for: status))
            } else if status != .unknown {
                LinkDots(paths: node.paths, inUse: inUse)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? theme.accent : theme.textTertiary)
        }
        .padding(.horizontal, Theme.gapL)
        .padding(.vertical, Theme.gapM + 2)
        .glassCard(isSelected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The state's own name, from the one mapping all three clients share. An
    /// online row says nothing here: the path label already said it.
    private var detail: String? {
        switch status {
        case .onlineLan, .onlineTunnel: return nil
        case .pendingApproval, .offline, .unknown:
            return l10n(MessageKeys.forNodeStatus(status))
        }
    }
}
