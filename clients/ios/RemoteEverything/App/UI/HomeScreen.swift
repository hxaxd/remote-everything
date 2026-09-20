import SwiftUI

/// S0 and S1: the empty state, and the merged list of every gateway's nodes.
struct HomeScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.reWideLayout) private var isWide

    var body: some View {
        let theme = Theme(colorScheme)
        VStack(spacing: 0) {
            if model.isRefreshing {
                LoadingLine()
            } else {
                Hairline()
            }
            content(theme)
        }
        .background(theme.bg)
        .navigationTitle(l10n(MessageKeys.APP_NAME))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await model.refreshNodes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    model.beginAddNode()
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    model.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
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
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.gapM)
                .padding(.vertical, Theme.gapS + 2)
                .background(theme.bgElevated)
                Hairline()
            }
            if model.identities.isEmpty && model.stagedSetups.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: l10n(MessageKeys.EMPTY_TITLE),
                        body: l10n(MessageKeys.EMPTY_BODY),
                        actionTitle: l10n(MessageKeys.ACTION_ADD_NODE),
                        action: { model.beginAddNode() }
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
                        body: l10n(MessageKeys.EMPTY_BODY),
                        actionTitle: l10n(MessageKeys.ACTION_ADD_NODE),
                        action: { model.beginAddNode() }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.gapXL * 2)
                }
                .refreshable { await model.refreshNodes() }
            } else {
                List {
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
                        .buttonStyle(.plain)
                        .listRowBackground(isSelected ? theme.tint(theme.accent) : theme.bgElevated)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
            StatusDot(color: theme.color(for: status))
            VStack(alignment: .leading, spacing: 2) {
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
                .font(Theme.caption)
                .foregroundStyle(isSelected ? theme.accent : theme.textTertiary)
        }
        .frame(minHeight: Theme.nodeRowHeight)
        .contentShape(Rectangle())
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
