import SwiftUI

/// Whether the screen is wide enough for S1 and S3 to stand side by side: the
/// line sits at 840 points on the short side, which is a
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
            ZStack(alignment: .bottom) {
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
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            model.notice = nil
                        }
                    }
                    .padding(.bottom, Theme.gapXL)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
                }
            }
            .background(theme.bg.ignoresSafeArea())
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(model.preferredColorScheme)
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
            // Narrow -> Wide: what was a full-screen page becomes the pane or the
            // detail beside the list — a pushed pairing becomes the add-node pane,
            // a pushed settings becomes the settings pane, a node at the root
            // becomes the selected detail.
            if let first = model.path.first {
                switch first {
                case .pair:
                    model.pane = .addNode
                    model.path.removeAll { if case .pair = $0 { return true }; return false }
                case .settings:
                    model.pane = .settings
                    model.path.removeAll { if case .settings = $0 { return true }; return false }
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
            // Wide -> Narrow: the pane becomes the phone's own full-screen shape —
            // settings a pushed page, pairing a pushed page — so nothing the
            // person had open is swallowed by the column change.
            switch model.pane {
            case .settings:
                model.pushSettings()
                model.pane = nil
            case .addNode:
                model.path.removeAll()
                model.path.append(.pair)
                model.selectedNodeID = nil
                model.pane = nil
            case nil:
                break
            }
            // A node selected in wide layout keeps its place at the root of the
            // phone's stack rather than kicking the person back to the list.
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
        switch model.pane {
        case .settings:
            SettingsScreen()
                .environmentObject(model)
        case .addNode:
            PairScreen()
                .environmentObject(model)
        case nil:
            if let nodeID = model.selectedNodeID {
                NodeScreen(nodeID: nodeID)
            } else {
                MessagePage(
                    title: l10n(MessageKeys.NODES_SELECT_HINT),
                    message: nil,
                    actionTitle: nil,
                    action: nil
                )
                .navigationTitle(l10n(MessageKeys.NODES_TITLE))
                .navigationBarTitleDisplayMode(.inline)
            }
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
        case .pair:
            PairScreen()
                .environmentObject(model)
        case .settings:
            SettingsScreen()
                .environmentObject(model)
        }
    }

    private func applicationName(nodeID: String, appID: String) -> String {
        model.catalogs[nodeID]?.applications.first { $0.id == appID }?.name ?? ""
    }
}
