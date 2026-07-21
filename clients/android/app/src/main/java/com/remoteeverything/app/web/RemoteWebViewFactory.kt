package com.remoteeverything.app.web

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.util.Log
import android.webkit.ClientCertRequest
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.net.toUri
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.ClientIdentity
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.GatewaySecurityPolicy
import com.remoteeverything.app.SecureHttp

/**
 * 远程应用 WebView 工厂。安全策略(mTLS 客户端证书、局域网证书固定、外链拦截)
 * 与旧版 RemoteWebView 逐行一致;新增加载进度、主文档错误检测、console 转发与
 * 电脑/手机显示模式(UA + 视口)。
 */
object RemoteWebViewFactory {
    const val MODE_PHONE = "phone"
    const val MODE_DESKTOP = "desktop"

    /** 桌面 Chrome UA,用于"电脑"显示模式。 */
    private const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    @SuppressLint("SetJavaScriptEnabled")
    fun create(
        context: Context,
        config: ConnectionConfig,
        identity: ClientIdentity?,
        displayMode: String,
        onExternal: (Uri) -> Unit,
        onCertificateFailure: () -> Unit,
        onRendererGone: (WebView) -> Unit,
        onProgress: (WebView, Int) -> Unit,
        onMainDocumentError: (WebView, String) -> Unit,
    ): WebView = WebView(context).apply {
        setBackgroundColor(Color.rgb(2, 6, 23))
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = false
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            safeBrowsingEnabled = true
            if (displayMode == MODE_DESKTOP) {
                userAgentString = DESKTOP_UA
                useWideViewPort = true
                loadWithOverviewMode = true
            }
        }
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                if (view != null) onProgress(view, newProgress)
            }

            override fun onConsoleMessage(message: ConsoleMessage?): Boolean {
                if (BuildConfig.DEBUG && message != null) {
                    Log.d("RemoteWebView", "[${message.messageLevel()}] ${message.message()} (@${message.sourceId()}:${message.lineNumber()})")
                }
                return false
            }
        }
        webViewClient = object : WebViewClient() {
            override fun onReceivedClientCertRequest(view: WebView?, request: ClientCertRequest) {
                val clientIdentity = identity
                val accepted = GatewaySecurityPolicy.allowsClientCertificate(config, clientIdentity != null, request.host, request.port)
                if (accepted && clientIdentity != null) request.proceed(clientIdentity.privateKey, clientIdentity.chain) else request.cancel()
            }

            @SuppressLint("WebViewClientOnReceivedSslError")
            override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler, error: android.net.http.SslError?) {
                val accepted = runCatching {
                    error != null && config.isGatewayUri(error.url.toUri()) && SecureHttp.acceptsPinnedWebViewError(config, error)
                }.getOrDefault(false)
                if (accepted) handler.proceed() else {
                    handler.cancel()
                    onCertificateFailure()
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean {
                if (GatewaySecurityPolicy.opensInsideWebView(config, request.url.toString())) return false
                onExternal(request.url)
                return true
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                super.onReceivedError(view, request, error)
                if (view != null && request?.isForMainFrame == true && error != null) {
                    onMainDocumentError(view, "${error.errorCode}: ${error.description}")
                }
            }

            override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (view != null && request?.isForMainFrame == true && errorResponse != null) {
                    onMainDocumentError(view, "HTTP ${errorResponse.statusCode}")
                }
            }

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                if (view != null) onRendererGone(view)
                return true
            }
        }
    }
}
