package com.remoteeverything.app.web

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Message
import android.util.Log
import android.view.View
import android.webkit.ClientCertRequest
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.net.toUri
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.ClientIdentity
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.GatewaySecurityPolicy
import com.remoteeverything.app.SecureHttp
import org.json.JSONObject

data class RemoteDownloadRequest(
    val url: String,
    val userAgent: String?,
    val contentDisposition: String?,
    val mimeType: String?,
    val contentLength: Long,
)

data class RemoteBlobDownload(
    val fileName: String,
    val mimeType: String,
    val base64: String,
)

data class RemoteWebViewCallbacks(
    val onExternal: (Uri) -> Unit,
    val onCertificateFailure: () -> Unit,
    val onRendererGone: (WebView) -> Unit,
    val onProgress: (WebView, Int) -> Unit,
    val onMainDocumentError: (WebView, String) -> Unit,
    val onFileChooser: (ValueCallback<Array<Uri>>, WebChromeClient.FileChooserParams) -> Boolean,
    val onPermissionRequest: (PermissionRequest) -> Unit,
    val onPermissionRequestCanceled: (PermissionRequest) -> Unit,
    val onDownload: (WebView, RemoteDownloadRequest) -> Unit,
    val onBlobDownload: (RemoteBlobDownload) -> Unit,
    val onPopupCreated: (WebView) -> Unit,
    val onPopupClosed: (WebView) -> Unit,
    val onShowCustomView: (View, WebChromeClient.CustomViewCallback) -> Unit,
    val onHideCustomView: () -> Unit,
    val onHostError: (String) -> Unit,
)

/** Native host for the remote applications' isolated WebViews. */
object RemoteWebViewFactory {
    const val MODE_PHONE = "phone"
    const val MODE_DESKTOP = "desktop"

    private const val BLOB_BRIDGE_NAME = "RemoteEverythingNativeDownloads"
    private const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    fun create(
        context: Context,
        config: ConnectionConfig,
        identity: ClientIdentity?,
        profileName: String,
        displayMode: String,
        callbacks: RemoteWebViewCallbacks,
    ): WebView = createConfigured(
        context = context,
        config = config,
        identity = identity,
        profileName = profileName,
        displayMode = displayMode,
        callbacks = callbacks,
        isPopup = false,
        allowPopups = true,
    )

    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    private fun createConfigured(
        context: Context,
        config: ConnectionConfig,
        identity: ClientIdentity?,
        profileName: String,
        displayMode: String,
        callbacks: RemoteWebViewCallbacks,
        isPopup: Boolean,
        allowPopups: Boolean,
    ): WebView {
        val webView = WebView(context)
        try {
            // The profile must be selected before any other WebView state is accessed.
            WebViewCompat.setProfile(webView, profileName)
        } catch (error: Throwable) {
            runCatching { webView.destroy() }
            throw error
        }

        webView.setBackgroundColor(Color.rgb(2, 6, 23))
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            // Uploads return user-approved content:// URIs. HTTPS pages still cannot load
            // arbitrary content-provider resources as subresources under WebView's origin rules.
            allowContentAccess = true
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = false
            setSupportMultipleWindows(allowPopups)
            javaScriptCanOpenWindowsAutomatically = false
            safeBrowsingEnabled = true
            if (displayMode == MODE_DESKTOP) {
                userAgentString = DESKTOP_UA
                useWideViewPort = true
                loadWithOverviewMode = true
            }
        }
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)

        val blobBridgeAvailable = runCatching { installBlobDownloadBridge(webView, config, callbacks) }
            .onFailure { Log.w("RemoteWebView", "Blob download bridge unavailable", it) }
            .getOrDefault(false)
        webView.setDownloadListener { url, userAgent, contentDisposition, mimeType, contentLength ->
            val value = url.orEmpty()
            when {
                value.startsWith("blob:") || value.startsWith("data:") -> callbacks.onHostError(
                    if (blobBridgeAvailable) "网页没有提供可保存的导出数据" else "当前网页内核不支持内存文件导出，请先更新 Android System WebView 或 Chrome",
                )
                config.isGatewayUrl(value) -> callbacks.onDownload(
                    webView,
                    RemoteDownloadRequest(value, userAgent, contentDisposition, mimeType, contentLength),
                )
                WebHostPolicy.allowsExternalIntent(value) -> callbacks.onHostError("外部下载地址需要在系统浏览器中打开")
                else -> callbacks.onHostError("已阻止不受信任的下载地址")
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                if (view != null) callbacks.onProgress(view, newProgress)
            }

            override fun onConsoleMessage(message: ConsoleMessage?): Boolean {
                if (BuildConfig.DEBUG && message != null) {
                    Log.d("RemoteWebView", "[${message.messageLevel()}] ${message.message()} (@${message.sourceId()}:${message.lineNumber()})")
                }
                return false
            }

            override fun onShowFileChooser(
                webView: WebView?,
                filePathCallback: ValueCallback<Array<Uri>>?,
                fileChooserParams: FileChooserParams?,
            ): Boolean {
                if (filePathCallback == null || fileChooserParams == null) return false
                return callbacks.onFileChooser(filePathCallback, fileChooserParams)
            }

            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                if (config.isGatewayUrl(request.origin.toString())) callbacks.onPermissionRequest(request) else request.deny()
            }

            override fun onPermissionRequestCanceled(request: PermissionRequest?) {
                if (request != null) callbacks.onPermissionRequestCanceled(request)
            }

            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message?,
            ): Boolean {
                if (!allowPopups || !isUserGesture || resultMsg == null) return false
                val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                val popup = runCatching {
                    createConfigured(
                        context = context,
                        config = config,
                        identity = identity,
                        profileName = profileName,
                        displayMode = displayMode,
                        callbacks = callbacks,
                        isPopup = true,
                        allowPopups = false,
                    )
                }.getOrElse {
                    callbacks.onHostError(it.message ?: "无法打开网页弹出页面")
                    return false
                }
                callbacks.onPopupCreated(popup)
                transport.webView = popup
                resultMsg.sendToTarget()
                return true
            }

            override fun onCloseWindow(window: WebView?) {
                if (window != null) callbacks.onPopupClosed(window)
            }

            override fun onShowCustomView(view: View?, callback: CustomViewCallback?) {
                if (view != null && callback != null) callbacks.onShowCustomView(view, callback)
            }

            override fun onHideCustomView() = callbacks.onHideCustomView()
        }

        var popupInitialNavigationAllowed = isPopup
        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedClientCertRequest(view: WebView?, request: ClientCertRequest) {
                val accepted = GatewaySecurityPolicy.allowsClientCertificate(
                    config,
                    identity != null,
                    request.host,
                    request.port,
                )
                if (accepted && identity != null) request.proceed(identity.privateKey, identity.chain) else request.cancel()
            }

            @SuppressLint("WebViewClientOnReceivedSslError")
            override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler, error: android.net.http.SslError?) {
                val accepted = runCatching {
                    error != null && config.isGatewayUri(error.url.toUri()) && SecureHttp.acceptsPinnedWebViewError(config, error)
                }.getOrDefault(false)
                if (accepted) handler.proceed() else {
                    handler.cancel()
                    callbacks.onCertificateFailure()
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean {
                val value = request.url.toString()
                if (GatewaySecurityPolicy.opensInsideWebView(config, value)) {
                    if (isPopup && request.isForMainFrame) popupInitialNavigationAllowed = false
                    return false
                }
                if (isPopup && value == "about:blank") return false
                val userAuthorized = request.hasGesture() || isPopup && request.isForMainFrame && popupInitialNavigationAllowed
                if (isPopup && request.isForMainFrame) popupInitialNavigationAllowed = false
                if (userAuthorized && WebHostPolicy.allowsExternalIntent(value)) {
                    callbacks.onExternal(request.url)
                } else {
                    callbacks.onHostError("已阻止网页自动打开外部地址")
                }
                if (isPopup && view != null) callbacks.onPopupClosed(view)
                return true
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                super.onReceivedError(view, request, error)
                if (!isPopup && view != null && request?.isForMainFrame == true && error != null) {
                    callbacks.onMainDocumentError(view, "${error.errorCode}: ${error.description}")
                }
            }

            override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (!isPopup && view != null && request?.isForMainFrame == true && errorResponse != null) {
                    callbacks.onMainDocumentError(view, "HTTP ${errorResponse.statusCode}")
                }
            }

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                if (view != null) {
                    if (isPopup) callbacks.onPopupClosed(view) else callbacks.onRendererGone(view)
                }
                return true
            }
        }
        return webView
    }

    @SuppressLint("RequiresFeature")
    private fun installBlobDownloadBridge(
        webView: WebView,
        config: ConnectionConfig,
        callbacks: RemoteWebViewCallbacks,
    ): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        ) return false

        val allowedOrigins = setOf(config.gatewayOrigin)
        WebViewCompat.addWebMessageListener(webView, BLOB_BRIDGE_NAME, allowedOrigins) { _, message, sourceOrigin, isMainFrame, _ ->
            if (!isMainFrame || !config.isGatewayUrl(sourceOrigin.toString()) || message.type != WebMessageCompat.TYPE_STRING) return@addWebMessageListener
            val failure = runCatching {
                val payload = JSONObject(requireNotNull(message.data) { "导出消息为空" })
                when (payload.getString("kind")) {
                    "blob" -> {
                        require(payload.length() == 4) { "导出消息字段无效" }
                        val base64 = payload.getString("base64")
                        require(WebHostPolicy.base64PayloadCanFit(base64)) { "导出文件超过 16 MiB 限制" }
                        callbacks.onBlobDownload(
                            RemoteBlobDownload(
                                fileName = WebHostPolicy.sanitizeDownloadName(payload.optString("name")),
                                mimeType = WebHostPolicy.normalizeMimeType(payload.optString("mime")),
                                base64 = base64,
                            ),
                        )
                    }
                    "error" -> {
                        require(payload.length() == 2) { "导出错误字段无效" }
                        callbacks.onHostError(payload.optString("message").take(200).ifBlank { "网页导出失败" })
                    }
                    else -> error("未知导出消息")
                }
            }.exceptionOrNull()
            if (failure != null) callbacks.onHostError(failure.message ?: "网页导出数据无效")
        }
        WebViewCompat.addDocumentStartJavaScript(webView, blobDownloadScript(), allowedOrigins)
        return true
    }

    private fun blobDownloadScript(): String = """
        (() => {
          if (window.__remoteEverythingDownloadBridgeInstalled) return;
          window.__remoteEverythingDownloadBridgeInstalled = true;
          const maxBytes = ${WebHostPolicy.MAX_BLOB_BYTES};
          const send = (payload) => {
            const bridge = window.$BLOB_BRIDGE_NAME;
            if (bridge && typeof bridge.postMessage === 'function') {
              bridge.postMessage(JSON.stringify(payload));
            }
          };
          document.addEventListener('click', (event) => {
            const element = event.target instanceof Element ? event.target.closest('a[download]') : null;
            if (!element || !(element.href.startsWith('blob:') || element.href.startsWith('data:'))) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            const source = element.href;
            const name = element.getAttribute('download') || 'download';
            (async () => {
              try {
                const response = await fetch(source);
                const blob = await response.blob();
                if (blob.size > maxBytes) {
                  send({kind: 'error', message: '导出文件超过 16 MiB 限制'});
                  return;
                }
                const reader = new FileReader();
                reader.onerror = () => send({kind: 'error', message: '无法读取网页导出数据'});
                reader.onload = () => {
                  const result = String(reader.result || '');
                  const comma = result.indexOf(',');
                  if (comma < 0) {
                    send({kind: 'error', message: '网页导出数据格式无效'});
                    return;
                  }
                  send({kind: 'blob', name, mime: blob.type || 'application/octet-stream', base64: result.slice(comma + 1)});
                };
                reader.readAsDataURL(blob);
              } catch (error) {
                send({kind: 'error', message: '网页导出失败'});
              }
            })();
          }, true);
        })();
    """.trimIndent()
}
