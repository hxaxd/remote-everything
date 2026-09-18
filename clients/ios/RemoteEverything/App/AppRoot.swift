import SwiftUI

/// Whether the screen is wide enough for S1 and S3 to stand side by side:
/// ui-contract §6 puts the line at 840 points on the short side, which is a
/// tablet or an unfolded foldable, and never changes by rotating.
private struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reWideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

/// The whole navigation of the app: S0/S1 as the root, S3 beside it or pushed,
/// S4 on top of that, and S2 and S5 as sheets.
struct AppRootView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let isWide = min(proxy.size.width, proxy.size.height) >= Theme.wideLayoutShortSide
            let theme = Theme(colorScheme)
            ZStack(alignment: .top) {
                Group {
                    if isWide {
                        wideLayout
                    } else {
                        narrowLayout
                    }
                }
                .environment(\.reWideLayout, isWide)
                if let notice = model.notice {
                    NoticeBanner(notice: notice) {
                        model.notice = nil
                    }
                    .padding(.top, Theme.gapS)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(theme.bg.ignoresSafeArea())
        }
        .preferredColorScheme(model.preferredColorScheme)
        .sheet(isPresented: $model.isAddingNode) {
            PairScreen()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsScreen()
                .environmentObject(model)
        }
        .onOpenURL { url in
            model.handleIncomingURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .task {
            model.start()
        }
    }

    private var narrowLayout: some View {
        NavigationStack(path: $model.path) {
            HomeScreen()
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            NavigationStack {
                HomeScreen()
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
            Rectangle()
                .fill(Theme(colorScheme).hairline)
                .frame(width: Theme.hairlineWidth)
            NavigationStack(path: $model.path) {
                detailColumn
                    .navigationDestination(for: AppRoute.self) { route in
                        destination(for: route)
                    }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let nodeID = model.selectedNodeID {
            NodeScreen(nodeID: nodeID)
        } else {
            MessagePage(
                title: l10n(MessageKeys.NODES_TITLE),
                body: l10n(MessageKeys.NODES_SELECT_HINT),
                actionTitle: nil,
                action: nil
            )
            .navigationTitle(l10n(MessageKeys.NODES_TITLE))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .node(let nodeID):
            NodeScreen(nodeID: nodeID)
        case .application(let nodeID, let appID):
            WebScreen(
                nodeID: nodeID,
                appID: appID,
                appName: applicationName(nodeID: nodeID, appID: appID)
            )
        }
    }

    private func applicationName(nodeID: String, appID: String) -> String {
        model.catalogs[nodeID]?.applications.first { $0.id == appID }?.name ?? ""
    }
}
