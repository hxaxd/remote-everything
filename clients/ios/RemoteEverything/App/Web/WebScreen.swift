import SwiftUI
import UIKit
import WebKit

/// S4: one application, full screen, in a WebView the gateway can ask for a
/// client certificate from.
///
/// Website data is persisted separately for each gateway and node application.
///
/// The screen belongs to the page: no title bar, no status bar, and everything a
/// chrome would carry waits behind the back gesture in `WebPanelView` — how the
/// screen is held, how the page introduces itself, a reload, and the way out.
/// Those two choices are per application and outlive the visit.
struct WebScreen: View {

    let nodeID: String
    let appID: String
    let appName: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var handle = WebViewHandle()
    @State private var target: WebTarget?
    @State private var openFailure: String?
    @State private var isResolving = true
    @State private var generation = 0
    @State private var prefs = WebAppPrefs()
    @State private var panelShown = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private let store = SettingsStore()

    private var appKey: String { "\(nodeID)/\(appID)" }

    var body: some View {
        let theme = Theme(colorScheme)
        ZStack {
            page(theme)
                .simultaneousGesture(backGesture)
                .ignoresSafeArea()
            if panelShown {
                WebPanelView(
                    theme: theme,
                    prefs: prefs,
                    onOrientation: { choose($0) },
                    onUserAgent: { choose($0) },
                    onRefresh: {
                        panelShown = false
                        handle.reloadPage()
                    },
                    onExit: { dismiss() },
                    onDismiss: { panelShown = false }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let notice {
                Text(notice)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, Theme.gapM)
                    .padding(.vertical, Theme.gapS)
                    .background(Capsule().fill(theme.bgElevated))
                    .padding(.top, Theme.gapL)
                    .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
        .task {
            prefs = store.webAppPrefs(for: appKey)
            OrientationLock.shared.apply(prefs.orientation)
            await resolve()
        }
        .onDisappear {
            // The next screen is not this application: the orientation goes back
            // to the system's, and the notice task has nothing left to say.
            OrientationLock.shared.release()
            noticeTask?.cancel()
            noticeTask = nil
        }
    }

    @ViewBuilder
    private func page(_ theme: Theme) -> some View {
        if let target {
            ZStack(alignment: .top) {
                GatewayWebView(
                    target: target,
                    storageIdentifier: WebSessionScope.identifier(gatewayOrigin: target.gatewayOrigin, appKey: appKey),
                    handle: handle,
                    interfaceStyle: interfaceStyle,
                    prefs: prefs,
                    onProcessTerminated: { generation += 1 },
                    onNotice: { show(notice: $0) }
                )
                .id("\(WebSessionScope.identifier(gatewayOrigin: target.gatewayOrigin, appKey: appKey))-\(generation)")
                if openFailure != nil || handle.phase == .failed {
                    failurePage(theme)
                        .background(theme.bg)
                } else if handle.phase == .loading {
                    // A page that is still coming up, or an application the
                    // node is still starting: a thin line says so instead of
                    // a blank screen.
                    LoadingLine()
                        .padding(.top, Theme.gapS)
                }
            }
        } else if isResolving {
            VStack {
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
        } else {
            failurePage(theme)
        }
    }

    private func failurePage(_ theme: Theme) -> some View {
        MessagePage(
            title: openFailure ?? l10n(MessageKeys.WEB_LOAD_FAILED),
            body: nil,
            actionTitle: l10n(MessageKeys.ACTION_RETRY),
            action: { Task { await resolve() } }
        )
    }

    /// The way back: a swipe from the screen's edge, from anywhere on it, which
    /// is the gesture people already have in their hands. It opens the panel
    /// rather than leaving — leaving is the panel's decision.
    private var backGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !panelShown,
                      value.startLocation.x < 28,
                      value.translation.width > 40 else { return }
                withAnimation(.easeOut(duration: 0.15)) { panelShown = true }
            }
    }

    // The setting changes; the panel stays. Refresh and Exit are the two that finish
    // something — a choice here is a choice a person may want to follow with another
    // one, and a menu that closes under the hand is a menu that has to be reopened.
    private func choose(_ orientation: WebOrientation) {
        prefs.orientation = orientation
        store.saveWebAppPrefs(prefs, for: appKey)
        OrientationLock.shared.apply(orientation)
    }

    private func choose(_ userAgent: WebUserAgent) {
        prefs.userAgent = userAgent
        store.saveWebAppPrefs(prefs, for: appKey)
        handle.setUserAgent(userAgent)
    }

    private func show(notice text: String) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { notice = text }
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private var interfaceStyle: UIUserInterfaceStyle {
        switch model.settings.appearance {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Every retry starts from the open request: the address is asked for again
    /// rather than remembered, which is what the contract asks for.
    private func resolve() async {
        isResolving = true
        openFailure = nil
        let previous = target
        do {
            let resolved = try await model.resolveWebTarget(nodeID: nodeID, appID: appID)
            target = resolved
            if previous?.gatewayOrigin == resolved.gatewayOrigin, handle.webView != nil {
                // The WebView is already up: a retry loads the address again,
                // whether or not it is the same one.
                handle.load(resolved.url)
            }
        } catch let error as ClientError {
            openFailure = ErrorText.text(for: error.code)
        } catch {
            openFailure = l10n(MessageKeys.APP_OPEN_FAILED)
        }
        isResolving = false
    }
}
