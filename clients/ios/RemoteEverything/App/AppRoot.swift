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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            // An iPad in portrait (>= 700pt), landscape (>= 1080pt), or Split View 2/3 has
            // room for two columns; Split View 1/3 (~320pt) or iPhones drop back to single pane.
            let isWide = verticalSizeClass != .compact && proxy.size.width >= 700
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
                .onChange(of: isWide) { _, wide in
                    handleLayoutTransition(toWide: wide)
                }
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

    /// Keep navigation state seamless when resizing or rotating between single-column and split-column.
    private func handleLayoutTransition(toWide: Bool) {
        if toWide {
            // Narrow -> Wide:
            // If the user navigated into a node in narrow layout, extract the root node route
            // to selectedNodeID so detailColumn displays it directly, leaving any child routes (e.g. .application)
            // pushed cleanly in the detail stack.
            if let first = model.path.first {
                switch first {
                case .node(let nodeID):
                    model.selectedNodeID = nodeID
                    model.path.removeFirst()
                case .application(let nodeID, _):
                    if model.selectedNodeID == nil {
                        model.selectedNodeID = nodeID
                    }
                }
            }
        } else {
            // Wide -> Narrow:
            // If a node was selected in wide layout, ensure it is at the root of model.path
            // so the user does not get kicked back to the home screen.
            if let selected = model.selectedNodeID {
                let hasNodeInPath = model.path.contains { route in
                    if case .node(let id) = route, id == selected { return true }
                    return false
                }
                if !hasNodeInPath {
                    model.path.insert(.node(selected), at: 0)
                }
            }
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
                title: l10n(MessageKeys.NODES_SELECT_HINT),
                body: nil,
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
