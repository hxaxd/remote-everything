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
        .navigationTitle(l10n(MessageKeys.NODES_TITLE))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
                    Button {
                        open(node)
                    } label: {
                        NodeRow(
                            node: node,
                            status: model.status(of: node),
                            showsPath: pathIsPrivate(node)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.bgElevated)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.refreshNodes() }
        }
    }

    private func pathIsPrivate(_ node: Node) -> Bool? {
        guard model.status(of: node).isOnline else { return nil }
        return PathSelector.choose(node.paths)?.isPrivate
    }

    private func open(_ node: Node) {
        if model.status(of: node) == .pendingApproval {
            // Waiting for the operator: there is nothing to show yet, and asking
            // again is what pull-to-refresh does.
            return
        }
        if isWide {
            model.selectedNodeID = node.id
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
    let showsPath: Bool?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme(colorScheme)
        HStack(spacing: Theme.gapM) {
            StatusDot(color: theme.color(for: status))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(Theme.headline)
                    .foregroundStyle(status == .offline || status == .unknown ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.gapS)
            if let showsPath {
                PathLabel(isPrivate: showsPath)
            }
            Image(systemName: "chevron.right")
                .font(Theme.caption)
                .foregroundStyle(theme.textTertiary)
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
