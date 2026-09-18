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
            if let node, let path = PathSelector.choose(node.paths) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    PathLabel(isPrivate: path.isPrivate)
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

    @ViewBuilder
    private func page(_ theme: Theme, node: Node?) -> some View {
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
                    body: l10n(MessageKeys.APPS_EMPTY_BODY),
                    actionTitle: l10n(MessageKeys.ACTION_RETRY),
                    action: { Task { await model.loadCatalog(nodeID: nodeID) } }
                )
            } else {
                List {
                    ForEach(apps) { app in
                        ApplicationRow(
                            app: app,
                            onOpen: { open(app) },
                            onStart: { model.startApplication(nodeID: nodeID, appID: app.id) },
                            onStop: { model.stopApplication(nodeID: nodeID, appID: app.id) }
                        )
                        .listRowBackground(theme.bgElevated)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await model.loadCatalog(nodeID: nodeID) }
            }
        case .some(.offline):
            MessagePage(
                title: l10n(MessageKeys.NODE_OFFLINE_TITLE),
                body: l10n(MessageKeys.NODE_OFFLINE_BODY),
                actionTitle: l10n(MessageKeys.ACTION_RETRY),
                action: { Task { await model.loadCatalog(nodeID: nodeID) } }
            )
        case .some(.unauthorized):
            MessagePage(
                title: l10n(MessageKeys.ERROR_NODE_GONE),
                body: nil,
                actionTitle: l10n(MessageKeys.ACTION_BACK_TO_NODES),
                action: { model.path.removeAll() }
            )
        case .some(.unreachable):
            MessagePage(
                title: ErrorText.network,
                body: node?.paths.isEmpty == false ? pathNames(node) : nil,
                actionTitle: l10n(MessageKeys.ACTION_RETRY),
                action: { Task { await model.loadCatalog(nodeID: nodeID) } }
            )
        case .some(.refused(let error)):
            MessagePage(
                title: ErrorText.text(for: error.code),
                body: nil,
                actionTitle: l10n(MessageKeys.ACTION_RETRY),
                action: { Task { await model.loadCatalog(nodeID: nodeID) } }
            )
        }
    }

    private func pathNames(_ node: Node?) -> String? {
        guard let node else { return nil }
        let labels = node.paths.map { $0.origin }.joined(separator: "\n")
        return labels.isEmpty ? nil : labels
    }

    /// Tapping an application opens it: running already, starting, or started
    /// first and then opened (S4 shows the start it is waiting for).
    private func open(_ app: AppInfo) {
        switch app.code {
        case .ready, .starting:
            model.path.append(.application(nodeID: nodeID, appID: app.id))
        case .stopped:
            model.startApplication(nodeID: nodeID, appID: app.id)
            model.path.append(.application(nodeID: nodeID, appID: app.id))
        case .stopping:
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
                    VStack(alignment: .leading, spacing: 2) {
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
            .buttonStyle(.plain)

            StatusBadge(text: stateText, color: theme.color(for: app.code))

            if app.code == .starting || app.code == .stopping {
                ProgressView()
                    .frame(width: 28)
            } else {
                Button(action: app.enabled ? onStop : onStart) {
                    Text(app.enabled ? l10n(MessageKeys.ACTION_STOP) : l10n(MessageKeys.ACTION_START))
                        .font(Theme.caption)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 44)
                        .padding(.vertical, Theme.gapS - 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: Theme.appRowHeight)
    }

    private var stateText: String {
        l10n(MessageKeys.forAppState(app.code))
    }
}
