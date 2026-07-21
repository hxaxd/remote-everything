import SwiftUI
import WebKit
import Security

/// Native WebView container for remote applications. Mirrors Android's `RemoteActivity`.
/// One WebView per app — full destroy on exit, no cross-app state sharing.
struct RemoteWebView: View {
    let config: ConnectionConfig
    let appId: String
    let appName: String
    let openUrl: String

    @Environment(\.dismiss) private var dismiss

    @State private var showControls = false
    @State private var failureMessage: String?
    @State private var pageGeneration = 0

    @AppStorage("theme_mode") private var themeMode = "system"
    @AppStorage("display_mode") private var displayMode = "mobile"

    var body: some View {
        ZStack {
            Color(hex: themeMode == "dark" ? "#0C0A09" : "#FAFAF9")
                .ignoresSafeArea()

            if let failure = failureMessage {
                failureView(failure)
            } else {
                WebViewContainer(
                    config: config,
                    appId: appId,
                    openUrl: openUrl,
                    displayMode: displayMode,
                    pageGeneration: pageGeneration,
                    onCertificateFailure: {
                        failureMessage = "服务器证书验证失败，已阻止连接"
                    },
                    onRendererGone: {
                        failureMessage = "网页内核异常退出"
                    },
                    onMainDocumentError: { detail in
                        failureMessage = detail
                    },
                    onExternal: { url in
                        UIApplication.shared.open(url)
                    }
                )
                .ignoresSafeArea()
                .id(pageGeneration)
            }
        }
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showControls = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
        }
        .sheet(isPresented: $showControls) {
            controlPanelView
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            pageGeneration += 1
        }
        .onDisappear {
            pageGeneration += 1
        }
    }

    // MARK: - Failure

    private func failureView(_ detail: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("远程页面没有成功打开")
                .font(.title3)
                .fontWeight(.bold)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("重试") {
                    failureMessage = nil
                    pageGeneration += 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    // MARK: - Control Panel

    private var controlPanelView: some View {
        NavigationStack {
            Form {
                Section("屏幕方向") {
                    Picker("方向", selection: .constant("global")) {
                        Text("跟随全局").tag("global")
                        Text("跟随系统").tag("system")
                        Text("竖屏").tag("portrait")
                        Text("横屏").tag("landscape")
                    }
                }

                Section("显示模式") {
                    Picker("模式", selection: $displayMode) {
                        Text("手机").tag("mobile")
                        Text("电脑").tag("desktop")
                    }
                    .onChange(of: displayMode) {
                        showControls = false
                        pageGeneration += 1
                    }
                }

                Section {
                    Button("重新加载页面") {
                        showControls = false
                        pageGeneration += 1
                    }

                    Button("返回目录", role: .destructive) {
                        showControls = false
                        dismiss()
                    }
                }
            }
            .navigationTitle(appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showControls = false }
                }
            }
        }
    }
}

// MARK: - WKWebView Wrapper

private struct WebViewContainer: UIViewRepresentable {
    let config: ConnectionConfig
    let appId: String
    let openUrl: String
    let displayMode: String
    let pageGeneration: Int
    let onCertificateFailure: () -> Void
    let onRendererGone: () -> Void
    let onMainDocumentError: (String) -> Void
    let onExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            config: config,
            appId: appId,
            openUrl: openUrl,
            onCertificateFailure: onCertificateFailure,
            onRendererGone: onRendererGone,
            onMainDocumentError: onMainDocumentError,
            onExternal: onExternal
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let profileId = WebIsolationPolicy.profileIdentifier(
            installationId: config.installationId,
            appId: appId
        )

        // Create isolated data store per installationId × appId
        let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: profileId) ?? UUID())
        let processPool = WKProcessPool()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.processPool = processPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        if displayMode == "desktop" {
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.backgroundColor = UIColor(red: 2/255, green: 6/255, blue: 23/255, alpha: 1)

        context.coordinator.webView = webView
        context.coordinator.dataStore = dataStore
        context.coordinator.loadPage(generation: pageGeneration)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.needsReload {
            context.coordinator.needsReload = false
            context.coordinator.loadPage(generation: pageGeneration)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let config: ConnectionConfig
        let appId: String
        let openUrl: String
        let onCertificateFailure: () -> Void
        let onRendererGone: () -> Void
        let onMainDocumentError: (String) -> Void
        let onExternal: (URL) -> Void

        weak var webView: WKWebView?
        var dataStore: WKWebsiteDataStore?
        var needsReload = false
        private var cookieSet = false
        private var currentGeneration = 0

        init(
            config: ConnectionConfig,
            appId: String,
            openUrl: String,
            onCertificateFailure: @escaping () -> Void,
            onRendererGone: @escaping () -> Void,
            onMainDocumentError: @escaping (String) -> Void,
            onExternal: @escaping (URL) -> Void
        ) {
            self.config = config
            self.appId = appId
            self.openUrl = openUrl
            self.onCertificateFailure = onCertificateFailure
            self.onRendererGone = onRendererGone
            self.onMainDocumentError = onMainDocumentError
            self.onExternal = onExternal
        }

        func loadPage(generation: Int) {
            currentGeneration = generation
            cookieSet = false

            guard let webView, let dataStore else { return }

            // Set the routing cookie before first navigation
            dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, self.currentGeneration == generation, let webView = self.webView else { return }

                // Remove old routing cookies
                for cookie in cookies where cookie.name == "RemoteEverythingApp" {
                    self.dataStore?.httpCookieStore.delete(cookie)
                }

                // Set routing cookie
                let cookieProps: [HTTPCookiePropertyKey: Any] = [
                    .name: "RemoteEverythingApp",
                    .value: self.appId,
                    .domain: URL(string: self.config.gatewayOrigin)?.host ?? "",
                    .path: "/",
                    .secure: true,
                    .init("HttpOnly"): true,
                    .init("SameSite"): "Strict",
                ]

                if let cookie = HTTPCookie(properties: cookieProps) {
                    self.dataStore?.httpCookieStore.setCookie(cookie) {
                        self.cookieSet = true
                        // Navigate to the app
                        if self.currentGeneration == generation {
                            var request = URLRequest(url: URL(string: self.webView?.url?.absoluteString ?? self.openUrl) ?? URL(string: "about:blank")!)
                            request.url = URL(string: self.openUrl)
                            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                            webView.load(request)
                        }
                    }
                } else {
                    // Cookie creation failed, try direct navigation
                    let request = URLRequest(url: URL(string: self.openUrl)!)
                    webView.load(request)
                }
            }
        }

        func cleanup() {
            webView?.stopLoading()
            webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Allow if within gateway origin
            if GatewaySecurityPolicy.isGatewayOrigin(url, config: config) {
                decisionHandler(.allow)
                return
            }

            // External URLs → system browser
            if navigationAction.navigationType == .linkActivated {
                onExternal(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let host = challenge.protectionSpace.host
            let port = challenge.protectionSpace.port

            // Server trust (LAN cert pinning)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                if config.mode == .lan {
                    if GatewaySecurityPolicy.validateLANTrust(
                        trust: trust,
                        host: host,
                        expectedFingerprint: config.gatewayFingerprint
                    ) {
                        completionHandler(.useCredential, URLCredential(trust: trust))
                    } else {
                        onCertificateFailure()
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                    return
                }
                // Public mode: use system trust
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // Client certificate (mTLS for public mode)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
                if GatewaySecurityPolicy.allowsClientCertificate(
                    config: config,
                    identityPresent: true,
                    host: host,
                    port: port
                ) {
                    // Load identity from keychain
                    if let identity = try? KeychainStore.loadIdentity(
                        installationId: config.installationId,
                        state: .active
                    ) {
                        var cert: SecCertificate?
                        SecIdentityCopyCertificate(identity, &cert)
                        let credential = URLCredential(
                            identity: identity,
                            certificates: cert.map { [$0] } ?? [],
                            persistence: .forSession
                        )
                        completionHandler(.useCredential, credential)
                        return
                    }
                }
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                onMainDocumentError("\(nsError.code): \(nsError.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Non-provisional failures — may be recoverable
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onRendererGone()
            // Reload the page
            webView.reload()
        }

        // MARK: - WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Open popups in system browser
            if let url = navigationAction.request.url {
                onExternal(url)
            }
            return nil
        }
    }
}
