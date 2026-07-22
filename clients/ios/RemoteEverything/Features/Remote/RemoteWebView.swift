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
    @State private var orientationMode: String
    @State private var displayMode: String

    init(config: ConnectionConfig, appId: String, appName: String, openUrl: String) {
        self.config = config
        self.appId = appId
        self.appName = appName
        self.openUrl = openUrl
        let settings = ClientSettings.shared
        _orientationMode = State(initialValue: settings.appOrientation(installationId: config.installationId, appId: appId))
        _displayMode = State(initialValue: settings.appDisplayMode(installationId: config.installationId, appId: appId))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if let failure = failureMessage {
                failureView(failure)
            } else {
                WebViewContainer(
                    config: config,
                    appId: appId,
                    openUrl: openUrl,
                    displayMode: resolvedDisplayMode,
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
                        if WebHostPolicy.mayOpenExternally(url) {
                            UIApplication.shared.open(url)
                        }
                    }
                )
                .ignoresSafeArea()
                .id(pageGeneration)
            }

            if failureMessage == nil && !showControls {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 24)
                        .gesture(
                            DragGesture(minimumDistance: 12).onEnded { value in
                                if value.translation.width > 40 { showControls = true }
                            }
                        )
                    Spacer(minLength: 0)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 24)
                        .gesture(
                            DragGesture(minimumDistance: 12).onEnded { value in
                                if value.translation.width < -40 { showControls = true }
                            }
                        )
                }
                .ignoresSafeArea()
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
            OrientationController.apply(resolvedOrientation)
        }
        .onDisappear {
            OrientationController.apply(ClientSettings.shared.globalOrientation)
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

                Button("返回目录") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
    }

    // MARK: - Control Panel

    private var controlPanelView: some View {
        NavigationStack {
            Form {
                Section("屏幕方向") {
                    Picker("方向", selection: $orientationMode) {
                        Text("跟随全局").tag("global")
                        Text("跟随系统").tag("system")
                        Text("竖屏").tag("portrait")
                        Text("横屏").tag("landscape")
                    }
                    .onChange(of: orientationMode) {
                        ClientSettings.shared.setAppOrientation(
                            orientationMode,
                            installationId: config.installationId,
                            appId: appId
                        )
                        OrientationController.apply(resolvedOrientation)
                    }
                }

                Section("显示模式") {
                    Picker("模式", selection: $displayMode) {
                        Text("跟随全局").tag("global")
                        Text("手机").tag("phone")
                        Text("电脑").tag("desktop")
                    }
                    .onChange(of: displayMode) {
                        ClientSettings.shared.setAppDisplayMode(
                            displayMode,
                            installationId: config.installationId,
                            appId: appId
                        )
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

    private var resolvedOrientation: String {
        orientationMode == "global" ? ClientSettings.shared.globalOrientation : orientationMode
    }

    private var resolvedDisplayMode: String {
        displayMode == "global" ? ClientSettings.shared.globalDisplayMode : displayMode
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
        let profileId: UUID?
        let profileError: Error?
        do {
            profileId = try WebDataStoreRegistry.shared.acquire(
                installationId: config.installationId,
                appId: appId
            )
            profileError = nil
        } catch {
            profileId = nil
            profileError = error
        }

        // Create isolated data store per installationId × appId
        let dataStore = profileId.map { WKWebsiteDataStore(forIdentifier: $0) }
            ?? WKWebsiteDataStore.nonPersistent()
        let processPool = WKProcessPool()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.processPool = processPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        configuration.defaultWebpagePreferences.preferredContentMode =
            displayMode == "desktop" ? .desktop : .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.backgroundColor = UIColor(red: 2/255, green: 6/255, blue: 23/255, alpha: 1)

        context.coordinator.webView = webView
        context.coordinator.dataStore = dataStore
        context.coordinator.dataStoreIdentifier = profileId
        if let profileError {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.onMainDocumentError(profileError.localizedDescription)
            }
        } else {
            context.coordinator.loadPage(generation: pageGeneration)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloads replace this representable through its generation-based identity.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, UIDocumentPickerDelegate {
        let config: ConnectionConfig
        let appId: String
        let openUrl: String
        let onCertificateFailure: () -> Void
        let onRendererGone: () -> Void
        let onMainDocumentError: (String) -> Void
        let onExternal: (URL) -> Void

        weak var webView: WKWebView?
        var dataStore: WKWebsiteDataStore?
        var dataStoreIdentifier: UUID?
        private var popupWebView: WKWebView?
        private var popupCloseButton: UIButton?
        private weak var exportController: UIDocumentPickerViewController?
        private var exportDirectory: URL?
        private var downloadDirectories: [ObjectIdentifier: URL] = [:]
        private weak var activeJavaScriptDialog: UIAlertController?
        private var activeJavaScriptCancellation: (() -> Void)?
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

            guard let webView,
                  let dataStore,
                  let target = URL(string: openUrl),
                  let host = URL(string: config.gatewayOrigin)?.host,
                  GatewaySecurityPolicy.isGatewayOrigin(target, config: config) else {
                onMainDocumentError("远程页面地址无效")
                return
            }

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
                    .domain: host,
                    .path: "/",
                    .secure: true,
                    .expires: Date().addingTimeInterval(86_400),
                    .init("HttpOnly"): true,
                    .init("SameSite"): "Strict",
                ]

                if let cookie = HTTPCookie(properties: cookieProps) {
                    self.dataStore?.httpCookieStore.setCookie(cookie) {
                        // Navigate to the app
                        if self.currentGeneration == generation {
                            var request = URLRequest(url: target)
                            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                            webView.load(request)
                        }
                    }
                } else {
                    self.onMainDocumentError("网页路由初始化失败")
                }
            }
        }

        func cleanup() {
            currentGeneration += 1
            activeJavaScriptCancellation?()
            exportController?.dismiss(animated: false)
            closePopup()
            for directory in downloadDirectories.values {
                try? FileManager.default.removeItem(at: directory)
            }
            if let exportDirectory {
                try? FileManager.default.removeItem(at: exportDirectory)
            }
            downloadDirectories.removeAll()
            exportDirectory = nil
            exportController = nil
            let currentWebView = webView
            currentWebView?.stopLoading()
            currentWebView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
            currentWebView?.navigationDelegate = nil
            currentWebView?.uiDelegate = nil
            webView = nil
            dataStore = nil
            if let dataStoreIdentifier {
                WebDataStoreRegistry.shared.release(identifier: dataStoreIdentifier)
                self.dataStoreIdentifier = nil
            }
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

            if navigationAction.shouldPerformDownload {
                decisionHandler(WebHostPolicy.mayDownload(url, config: config) ? .download : .cancel)
                return
            }

            if GatewaySecurityPolicy.isGatewayOrigin(url, config: config) {
                decisionHandler(.allow)
                return
            }

            if navigationAction.navigationType == .linkActivated,
               WebHostPolicy.mayOpenExternally(url) {
                onExternal(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard let responseURL = navigationResponse.response.url,
                  WebHostPolicy.mayDownload(responseURL, config: config) else {
                decisionHandler(.cancel)
                return
            }
            let httpResponse = navigationResponse.response as? HTTPURLResponse
            if navigationResponse.isForMainFrame,
               let status = httpResponse?.statusCode,
               status >= 400 {
                onMainDocumentError("网页服务返回 \(status)")
                decisionHandler(.cancel)
                return
            }
            let disposition = httpResponse?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if !navigationResponse.canShowMIMEType || disposition.contains("attachment") {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
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
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == NSURLErrorDomain {
                onMainDocumentError("\(nsError.code): \(nsError.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            onMainDocumentError("\(nsError.code): \(nsError.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onRendererGone()
        }

        // MARK: - WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            guard webView === self.webView else { return nil }
            if let target = navigationAction.request.url,
               target.scheme?.lowercased() != "about",
               !GatewaySecurityPolicy.isGatewayOrigin(target, config: config) {
                if WebHostPolicy.mayOpenExternally(target) { onExternal(target) }
                return nil
            }
            closePopup()

            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = false
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.backgroundColor = .systemBackground
            webView.addSubview(popup)

            let closeButton = UIButton(type: .system)
            closeButton.setTitle("关闭", for: .normal)
            closeButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
            closeButton.layer.cornerRadius = 14
            closeButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.addTarget(self, action: #selector(closePopupAction), for: .touchUpInside)
            webView.addSubview(closeButton)

            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
                popup.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
                popup.topAnchor.constraint(equalTo: webView.topAnchor),
                popup.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
                closeButton.topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 8),
                closeButton.trailingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            ])
            popupWebView = popup
            popupCloseButton = closeButton
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView === popupWebView { closePopup() }
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            guard WebHostPolicy.isGatewayOrigin(origin, config: config), frame.isMainFrame else {
                decisionHandler(.deny)
                return
            }
            decisionHandler(.prompt)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard WebHostPolicy.isGatewayOrigin(frame.securityOrigin, config: config) else {
                completionHandler()
                return
            }
            let resolver = OneShotCompletion<Void> { _ in completionHandler() }
            let alert = UIAlertController(
                title: "来自 \(frame.securityOrigin.host)",
                message: String(message.prefix(4_096)),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
                if let self {
                    self.resolveJavaScriptDialog(resolver, value: ())
                } else {
                    resolver.resolve(())
                }
            })
            presentJavaScriptDialog(alert) {
                resolver.resolve(())
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard WebHostPolicy.isGatewayOrigin(frame.securityOrigin, config: config) else {
                completionHandler(false)
                return
            }
            let resolver = OneShotCompletion<Bool>(completionHandler)
            let alert = UIAlertController(
                title: "来自 \(frame.securityOrigin.host)",
                message: String(message.prefix(4_096)),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                if let self {
                    self.resolveJavaScriptDialog(resolver, value: false)
                } else {
                    resolver.resolve(false)
                }
            })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
                if let self {
                    self.resolveJavaScriptDialog(resolver, value: true)
                } else {
                    resolver.resolve(true)
                }
            })
            presentJavaScriptDialog(alert) {
                resolver.resolve(false)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard WebHostPolicy.isGatewayOrigin(frame.securityOrigin, config: config) else {
                completionHandler(nil)
                return
            }
            let resolver = OneShotCompletion<String?>(completionHandler)
            let alert = UIAlertController(
                title: "来自 \(frame.securityOrigin.host)",
                message: String(prompt.prefix(4_096)),
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.text = defaultText.map { String($0.prefix(4_096)) }
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                if let self {
                    self.resolveJavaScriptDialog(resolver, value: nil)
                } else {
                    resolver.resolve(nil)
                }
            })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
                let value = alert?.textFields?.first?.text
                if let self {
                    self.resolveJavaScriptDialog(resolver, value: value)
                } else {
                    resolver.resolve(value)
                }
            })
            presentJavaScriptDialog(alert) {
                resolver.resolve(nil)
            }
        }

        // MARK: - Download export picker

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if controller === exportController {
                cleanupExport()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            if controller === exportController {
                cleanupExport()
            }
        }

        // MARK: - Downloads

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            guard let originalURL = download.originalRequest?.url,
                  WebHostPolicy.mayDownload(originalURL, config: config),
                  let responseURL = response.url,
                  WebHostPolicy.mayDownload(responseURL, config: config) else {
                completionHandler(nil)
                return
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteEverything-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                downloadDirectories[ObjectIdentifier(download)] = directory
                completionHandler(directory.appendingPathComponent(WebHostPolicy.safeFilename(suggestedFilename)))
            } catch {
                completionHandler(nil)
            }
        }

        func download(
            _ download: WKDownload,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
        ) {
            guard let target = request.url,
                  WebHostPolicy.mayFollowDownloadRedirect(target, config: config) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let directory = downloadDirectories.removeValue(forKey: ObjectIdentifier(download)) else {
                return
            }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            guard let file = files.first, let presenter = presenter(), exportController == nil else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            exportDirectory = directory
            exportController = picker
            presenter.present(picker, animated: true)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let directory = downloadDirectories.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        func download(
            _ download: WKDownload,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let host = challenge.protectionSpace.host
            let port = challenge.protectionSpace.port
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               config.mode == .lan {
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
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
               GatewaySecurityPolicy.allowsClientCertificate(
                config: config,
                identityPresent: true,
                host: host,
                port: port
               ),
               let identity = try? KeychainStore.loadIdentity(
                installationId: config.installationId,
                state: .active
               ) {
                var certificate: SecCertificate?
                SecIdentityCopyCertificate(identity, &certificate)
                completionHandler(
                    .useCredential,
                    URLCredential(
                        identity: identity,
                        certificates: certificate.map { [$0] } ?? [],
                        persistence: .forSession
                    )
                )
                return
            }
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }

        // MARK: - Helpers

        @objc private func closePopupAction() {
            closePopup()
        }

        private func closePopup() {
            popupWebView?.stopLoading()
            popupWebView?.navigationDelegate = nil
            popupWebView?.uiDelegate = nil
            popupWebView?.removeFromSuperview()
            popupCloseButton?.removeFromSuperview()
            popupWebView = nil
            popupCloseButton = nil
        }

        private func cleanupExport() {
            if let exportDirectory {
                try? FileManager.default.removeItem(at: exportDirectory)
            }
            exportDirectory = nil
            exportController = nil
        }

        private func presentJavaScriptDialog(
            _ alert: UIAlertController,
            cancellation: @escaping () -> Void
        ) {
            guard activeJavaScriptCancellation == nil, let presenter = presenter() else {
                cancellation()
                return
            }
            activeJavaScriptDialog = alert
            activeJavaScriptCancellation = { [weak self, weak alert] in
                alert?.dismiss(animated: false)
                self?.activeJavaScriptDialog = nil
                self?.activeJavaScriptCancellation = nil
                cancellation()
            }
            presenter.present(alert, animated: true)
        }

        private func resolveJavaScriptDialog<Value>(
            _ resolver: OneShotCompletion<Value>,
            value: Value
        ) {
            guard resolver.resolve(value) else { return }
            activeJavaScriptDialog = nil
            activeJavaScriptCancellation = nil
        }

        private func presenter() -> UIViewController? {
            guard let root = webView?.window?.rootViewController else { return nil }
            var current = root
            while let presented = current.presentedViewController { current = presented }
            if let navigation = current as? UINavigationController {
                return navigation.visibleViewController ?? navigation
            }
            return current
        }
    }
}
