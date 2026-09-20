import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
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
    var onReload: ((URL) -> Void)?
    var onUserAgent: ((WebUserAgent) -> Void)?
    var onReloadPage: (() -> Void)?

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
        if let onReload {
            onReload(url)
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    /// The page again, as it is: what the panel's refresh means.
    func reloadPage() {
        phase = .loading
        onReloadPage?()
    }

    /// A different introduction, and the page fetched again so it hears it.
    func setUserAgent(_ mode: WebUserAgent) {
        onUserAgent?(mode)
    }
}

/// The application's page, in the WebView the gateway's client certificate can
/// be presented from.
///
/// It is one WKWebView for the life of the screen: rotating the device does not
/// touch it (ui-contract §2/S4), and the only thing that rebuilds it is the web
/// content process dying, which the screen asks for by changing the view's id.
///
/// Everything a page may ask the device for is answered here: a file to upload
/// (WebKit's own picker), a file to download (through this gateway's TLS, into
/// the share sheet), the camera and the microphone, a popup, a link that leaves
/// the gateway. Each answer is scoped to the gateway's hosts, the same way the
/// certificate is.
struct GatewayWebView: UIViewRepresentable {

    let target: WebTarget
    let storageIdentifier: UUID
    let handle: WebViewHandle
    let interfaceStyle: UIUserInterfaceStyle
    let prefs: WebAppPrefs
    let onProcessTerminated: () -> Void
    let onNotice: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            target: target,
            handle: handle,
            onProcessTerminated: onProcessTerminated,
            onNotice: onNotice
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storageIdentifier)
        // Applications such as video conferences and music players run on their
        // own: requiring a gesture is what made them look broken. Inline video is
        // on, and its fullscreen button is the system's own player.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(
            context.coordinator.blobRelay,
            name: Coordinator.blobMessageName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.overrideUserInterfaceStyle = interfaceStyle
        webView.isOpaque = true
        webView.backgroundColor = UIColor.systemBackground
        handle.attach(webView)
        handle.onReload = { [weak coordinator = context.coordinator] url in
            coordinator?.load(url, force: true)
        }
        handle.onReloadPage = { [weak coordinator = context.coordinator] in
            coordinator?.webView?.reload()
        }
        handle.onUserAgent = { [weak coordinator = context.coordinator] mode in
            coordinator?.applyUserAgent(mode, reload: true)
        }
        context.coordinator.webView = webView
        context.coordinator.rememberDefaultUserAgent()
        context.coordinator.applyUserAgent(prefs.userAgent, reload: false)
        context.coordinator.load(target.url)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only ever the appearance: reloading here would reload on every state
        // change the screen makes, which is the bug this whole structure avoids.
        webView.overrideUserInterfaceStyle = interfaceStyle
        context.coordinator.update(target: target)
        context.coordinator.update(prefs: prefs)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.blobMessageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

        static let blobMessageName = "RemoteEverythingBlob"

        private var target: WebTarget
        private let handle: WebViewHandle
        private let onProcessTerminated: () -> Void
        private let onNotice: (String) -> Void
        private(set) var loadedURL: URL?
        weak var webView: WKWebView?

        private var appliedUserAgent: WebUserAgent?
        private var defaultUserAgent: String?
        private var savedDownloads: [ObjectIdentifier: URL] = [:]
        private var blobSinks: [String: BlobSink] = [:]

        private struct BlobSink {
            /// The type the page declared, replaced when the data URL says what it is.
            var mime: String
            var data: Data
        }

        /// The relay exists because userContentController holds its handler
        /// strongly and the handler is this coordinator: without the indirection
        /// the two would keep each other alive for the life of the app.
        lazy var blobRelay = ScriptMessageRelay { [weak self] message in
            self?.receive(blobMessage: message)
        }

        init(
            target: WebTarget,
            handle: WebViewHandle,
            onProcessTerminated: @escaping () -> Void,
            onNotice: @escaping (String) -> Void
        ) {
            self.target = target
            self.handle = handle
            self.onProcessTerminated = onProcessTerminated
            self.onNotice = onNotice
        }

        func update(target: WebTarget) {
            self.target = target
        }

        func update(prefs: WebAppPrefs) {
            applyUserAgent(prefs.userAgent, reload: false)
        }

        /// Loads the address once. Nothing here publishes: this runs while the
        /// view is being built, and a state change during a view update is a
        /// change SwiftUI did not ask for. The phase follows the navigation
        /// callbacks instead.
        func load(_ url: URL, force: Bool = false) {
            guard force || loadedURL != url else { return }
            loadedURL = url
            webView?.load(URLRequest(url: url))
        }

        // MARK: - The page's own identity

        /// The agent WebKit would send, kept so a desktop one can be derived from
        /// the engine that is actually rendering.
        func rememberDefaultUserAgent() {
            webView?.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                self?.defaultUserAgent = value as? String
            }
        }

        func applyUserAgent(_ mode: WebUserAgent, reload: Bool) {
            guard let webView else { return }
            let changed = appliedUserAgent != mode
            appliedUserAgent = mode
            switch mode {
            case .mobile:
                webView.customUserAgent = nil
            case .desktop:
                webView.customUserAgent = Coordinator.desktopUserAgent(from: defaultUserAgent)
            }
            if reload, changed {
                // The page is loaded again, rather than reloaded: a reload re-sends
                // the request that was last made, headers and all, so the identity
                // just chosen would only appear on the load after next.
                if let current = webView.url {
                    webView.load(URLRequest(url: current))
                } else {
                    webView.reload()
                }
            }
        }

        /// A page that asks for a desktop is asking for a desktop: the mobile
        /// token goes, the phone becomes a Mac, and the engine and its version
        /// stay — they are the truth about what is rendering.
        static func desktopUserAgent(from mobile: String?) -> String {
            let engine = mobile.flatMap { firstMatch(of: "AppleWebKit/[\\d.]+", in: $0) } ?? "AppleWebKit/605.1.15"
            let version = mobile.flatMap { firstMatch(of: "Version/[\\d.]+", in: $0) } ?? "Version/17.0"
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \(engine) (KHTML, like Gecko) \(version) Safari/605.1.15"
        }

        private static func firstMatch(of pattern: String, in value: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(value.startIndex..., in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                  let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
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
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            // A link that says "download" is one: the download keeps this
            // WebView's TLS answer, which the system downloader could not give.
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            switch scheme {
            case "https":
                if target.handler.isGatewayHost(url.host ?? "") {
                    decisionHandler(.allow)
                } else {
                    // Anything that leaves the gateway goes to the system browser:
                    // this WebView carries a device certificate, and it is not for
                    // other sites.
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                }
            case "blob":
                // A blob only lives in the page: the page reads it and hands the
                // bytes over, and the navigation is cancelled.
                decisionHandler(.cancel)
                fetchBlob(url)
            case "data":
                decisionHandler(.cancel)
                saveDataURL(url)
            default:
                // tel:, mailto:, and whatever else the page links to: the system's.
                UIApplication.shared.open(url)
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

        // MARK: - What the page may ask the device for

        /// window.open / target=_blank: the page arrives here, in the page that
        /// asked; there is no second window to keep track of.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// The page asks for the camera or the microphone. The gateway's own
        /// pages may have them, and the platform's own question is asked before
        /// the page is told yes.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            guard target.handler.isGatewayHost(origin.host) else {
                decisionHandler(.deny)
                return
            }
            let needed: [AVMediaType]
            switch type {
            case .camera: needed = [.video]
            case .microphone: needed = [.audio]
            case .cameraAndMicrophone: needed = [.video, .audio]
            default: needed = [.video, .audio]
            }
            let group = DispatchGroup()
            for media in needed where AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                group.enter()
                AVCaptureDevice.requestAccess(for: media) { _ in group.leave() }
            }
            group.notify(queue: .main) { decisionHandler(.grant) }
        }

        // MARK: - Downloads

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
            let destination = Coordinator.downloadsDirectory()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(sanitised(suggestedFilename))
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            savedDownloads[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let file = savedDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            onNotice(l10n(MessageKeys.WEB_DOWNLOAD_SAVED, file.lastPathComponent))
            Coordinator.share(file)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            savedDownloads.removeValue(forKey: ObjectIdentifier(download))
            onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
        }

        // MARK: - Blobs: bytes the page holds and no server serves

        private func fetchBlob(_ url: URL) {
            let token = UUID().uuidString
            blobSinks[token] = BlobSink(mime: "application/octet-stream", data: Data())
            let script = """
            (async () => {
              const post = (message) => window.webkit.messageHandlers.\(Coordinator.blobMessageName).postMessage(message);
              const b64 = (bytes) => {
                let text = '';
                for (let i = 0; i < bytes.length; i += 32768) {
                  text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
                }
                return btoa(text);
              };
              try {
                const response = await fetch(\(Coordinator.javascriptString(url.absoluteString)));
                const blob = await response.blob();
                post({ token: \(Coordinator.javascriptString(token)), kind: 'begin', data: blob.type || '' });
                const reader = blob.stream().getReader();
                while (true) {
                  const { done, value } = await reader.read();
                  if (done) break;
                  post({ token: \(Coordinator.javascriptString(token)), kind: 'append', data: b64(value) });
                }
                post({ token: \(Coordinator.javascriptString(token)), kind: 'end' });
              } catch (error) {
                post({ token: \(Coordinator.javascriptString(token)), kind: 'fail' });
              }
            })();
            """
            webView?.evaluateJavaScript(script)
        }

        private func receive(blobMessage: [String: Any]) {
            guard let token = blobMessage["token"] as? String,
                  let kind = blobMessage["kind"] as? String,
                  var sink = blobSinks[token] else { return }
            switch kind {
            case "begin":
                sink.mime = (blobMessage["data"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sink.mime
                blobSinks[token] = sink
            case "append":
                if let chunk = blobMessage["data"] as? String, let bytes = Data(base64Encoded: chunk) {
                    sink.data.append(bytes)
                    blobSinks[token] = sink
                }
            case "end":
                blobSinks.removeValue(forKey: token)
                finish(blob: sink)
            default:
                blobSinks.removeValue(forKey: token)
                onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
            }
        }

        private func finish(blob sink: BlobSink) {
            guard !sink.data.isEmpty else {
                onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
                return
            }
            let extensionName = UTType(mimeType: sink.mime)?.preferredFilenameExtension
            let name = extensionName.map { "download.\($0)" } ?? "download"
            let file = Coordinator.downloadsDirectory()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try sink.data.write(to: file)
            } catch {
                onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
                return
            }
            onNotice(l10n(MessageKeys.WEB_DOWNLOAD_SAVED, file.lastPathComponent))
            Coordinator.share(file)
        }

        /// A data: URL is already here: it only has to be decoded and written.
        private func saveDataURL(_ url: URL) {
            let text = url.absoluteString
            guard let comma = text.firstIndex(of: ","), text[..<comma].hasSuffix(";base64") else {
                onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
                return
            }
            let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
            let mime = header.replacingOccurrences(of: ";base64", with: "")
            let payload = String(text[text.index(after: comma)...])
            guard let bytes = Data(base64Encoded: payload) else {
                onNotice(l10n(MessageKeys.WEB_DOWNLOAD_FAILED))
                return
            }
            var sink = BlobSink(mime: mime.isEmpty ? "application/octet-stream" : mime, data: Data())
            sink.data = bytes
            finish(blob: sink)
        }

        private func sanitised(_ name: String) -> String {
            let cleaned = name
                .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
                .joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "download" : String(cleaned.suffix(120))
        }

        /// Where a download lands: the app's own Documents folder, in a Downloads
        /// directory of its own. The app is file-sharing enabled (Info.plist), so
        /// that directory is the one the person can see in Files and open from —
        /// a temporary directory would be a file that quietly disappears.
        private static func downloadsDirectory() -> URL {
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }

        /// A saved file is offered, not filed away: the share sheet is how it
        /// reaches Files, another app, or the person watching.
        private static func share(_ file: URL) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                var controller = scene.keyWindow?.rootViewController else { return }
            while let presented = controller.presentedViewController { controller = presented }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = controller.view
            controller.present(sheet, animated: true)
        }

        private static func javascriptString(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
    }
}

/// Keeps the message handler from keeping its owner alive: userContentController
/// retains what it is given, and what it is given is the coordinator that owns
/// the WebView, so the coordinator is reached through a handler that holds it
/// weakly. (Not private: the coordinator's property is internal, and a private
/// type may not appear in it.)
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {

    private let onMessage: ([String: Any]) -> Void

    init(onMessage: @escaping ([String: Any]) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage(body)
    }
}
