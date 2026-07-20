package com.remoteeverything.app

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.webkit.ClientCertRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.net.toUri

object RemoteWebView {
    @SuppressLint("SetJavaScriptEnabled")
    fun create(
        context: Context,
        config: ConnectionConfig,
        identity: ClientIdentity?,
        onExternal: (Uri) -> Unit,
        onCertificateFailure: () -> Unit,
        onRendererGone: () -> Unit,
    ): WebView = WebView(context).apply {
        setBackgroundColor(Ui.bg)
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
                runCatching { view?.destroy() }
                onRendererGone()
                return true
            }
        }
    }
}
