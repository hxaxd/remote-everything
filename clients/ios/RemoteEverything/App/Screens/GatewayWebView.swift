import SwiftUI
import UIKit
import WebKit

/// What a screen can ask of the WebView it owns, and what the WebView tells it
/// back. Plain (not main-actor isolated) on purpose: WebKit calls its delegates
/// on the main thread, and a handle that could only be touched from the main
/// actor would force the delegates to hop for no reason.
final class WebViewHandle: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published var canGoBack = false
    @Published var phase: Phase = .loading

    weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func goBack() {
        webView?.goBack()
    }

    /// Loads a URL again, on purpose: a retry re-resolves the address first, and
    /// the result may be the same URL.
    func load(_ url: URL) {
        phase = .loading
        webView?.load(URLRequest(url: url))
    }
}

/// The application's page, in the WebView the gateway's client certificate can
/// be presented from.
///
/// It is one WKWebView for the life of the screen: rotating the device does not
/// touch it (ui-contract §2/S4), and the only thing that rebuilds it is the web
/// content process dying, which the screen asks for by changing the view's id.
struct GatewayWebView: UIViewRepresentable {

    let target: WebTarget
    let handle: WebViewHandle
    let interfaceStyle: UIUserInterfaceStyle
    let onProcessTerminated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            target: target,
            handle: handle,
            onProcessTerminated: onProcessTerminated
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // One store for the whole app: an application's storage is separated by
        // its origin, which the gateway gives it, not by anything this client
        // does (architecture §6.2).
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.overrideUserInterfaceStyle = interfaceStyle
        webView.isOpaque = true
        webView.backgroundColor = UIColor.systemBackground
        handle.attach(webView)
        context.coordinator.webView = webView
        context.coordinator.load(target.url)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only ever the appearance: reloading here would reload on every state
        // change the screen makes, which is the bug this whole structure avoids.
        webView.overrideUserInterfaceStyle = interfaceStyle
        context.coordinator.update(target: target)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {

        private var target: WebTarget
        private let handle: WebViewHandle
        private let onProcessTerminated: () -> Void
        private var loadedURL: URL?
        weak var webView: WKWebView?

        init(target: WebTarget, handle: WebViewHandle, onProcessTerminated: @escaping () -> Void) {
            self.target = target
            self.handle = handle
            self.onProcessTerminated = onProcessTerminated
        }

        func update(target: WebTarget) {
            self.target = target
        }

        /// Loads the address once. Nothing here publishes: this runs while the
        /// view is being built, and a state change during a view update is a
        /// change SwiftUI did not ask for. The phase follows the navigation
        /// callbacks instead.
        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            webView?.load(URLRequest(url: url))
        }

        // MARK: - Navigation

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // One of the three places iOS asks: this one, URLSession and the
            // download below all answer through the same handler.
            target.handler.respond(to: challenge, completionHandler: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == "https" || scheme == "http" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            handle.phase = .loading
            handle.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            handle.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            handle.canGoBack = webView.canGoBack
            handle.phase = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle.phase = .failed
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handle.phase = .failed
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The process that died is not this one: ask for the view to be
            // rebuilt rather than leaving a blank page behind.
            onProcessTerminated()
        }

        // MARK: - Downloads

        /// A page that starts a download. Downloads belong to the API layer (the
        /// system downloader carries no certificate), and v1 does not do them:
        /// the delegate is set so the challenge is still answered by this
        /// handler, and the destination is refused rather than half-done.
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            target.handler.respond(to: challenge, completionHandler: completionHandler)
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
