import SwiftUI
import UIKit
import WebKit

/// S4: one application, full screen, in a WebView the gateway can ask for a
/// client certificate from.
///
/// The page is the application's own origin — the address `open` answered with —
/// so its storage belongs to it alone. Nothing is injected and nothing is
/// isolated here; that is the server's design, and the client's whole job is to
/// load the address and be able to authenticate.
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

    var body: some View {
        let theme = Theme(colorScheme)
        Group {
            if let target {
                ZStack(alignment: .top) {
                    GatewayWebView(
                        target: target,
                        handle: handle,
                        interfaceStyle: interfaceStyle,
                        onProcessTerminated: { generation += 1 }
                    )
                    .id(generation)
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
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // The back gesture consumes the WebView's own history first;
                    // only an empty stack leaves the screen.
                    if handle.canGoBack {
                        handle.goBack()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let target {
                    PathLabel(isPrivate: target.isPrivate)
                }
            }
        }
        .task { await resolve() }
    }

    private func failurePage(_ theme: Theme) -> some View {
        MessagePage(
            title: openFailure ?? l10n(MessageKeys.WEB_LOAD_FAILED),
            body: nil,
            actionTitle: l10n(MessageKeys.ACTION_RETRY),
            action: { Task { await resolve() } }
        )
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
            if previous != nil, handle.webView != nil {
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
