package com.remoteeverything.app.web

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.webkit.ClientCertRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
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
 * 与旧版 RemoteWebView 逐行一致,仅新增加载进度回调供顶部进度条使用。
 */
object RemoteWebViewFactory {
    @SuppressLint("SetJavaScriptEnabled")
    fun create(
        context: Context,
        config: ConnectionConfig,
        identity: ClientIdentity?,
        onExternal: (Uri) -> Unit,
        onCertificateFailure: () -> Unit,
        onRendererGone: (WebView) -> Unit,
        onProgress: (WebView, Int) -> Unit,
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
        }
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                if (view != null) onProgress(view, newProgress)
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

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                if (view != null) onRendererGone(view)
                return true
            }
        }
    }
}
