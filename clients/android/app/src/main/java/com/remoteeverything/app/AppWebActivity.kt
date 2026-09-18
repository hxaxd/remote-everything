package com.remoteeverything.app

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import com.remoteeverything.core.identity.AndroidKeyStoreIdentityVault
import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.model.Digest
import com.remoteeverything.core.model.ServerPin
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * One application, on its own origin, in a WebView of its own — a plain view
 * tree in a dedicated activity, because a WebView inside a navigating Compose
 * screen loses touches, focus and its own lifecycle. The identity is resolved
 * before the first navigation: the certificate challenge arrives on the network
 * thread and can only be answered synchronously, so by the time it does, the
 * key is already in memory.
 */
class AppWebActivity : ComponentActivity() {

    private lateinit var web: WebView
    private lateinit var container: FrameLayout
    private var popup: WebView? = null
    private var material: Pkcs12.Material? = null
    private var identityHost: String = ""
    private var serverPin: ServerPin? = null
    private var appUrl: String = ""
    private var crashCount = 0

    private val vault by lazy { AndroidKeyStoreIdentityVault() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val target = intent.getStringExtra(ExtraUrl) ?: return finish()
        val imageOrigin = intent.getStringExtra(ExtraIdentityOrigin) ?: return finish()
        val appName = intent.getStringExtra(ExtraAppName).orEmpty()
        val nodeName = intent.getStringExtra(ExtraNodeName).orEmpty()
        val dark = intent.getBooleanExtra(ExtraDark, false)
        serverPin = intent.getStringExtra(ExtraPinPublicKey)?.let { publicKeyPin ->
            ServerPin(
                certFingerprint = intent.getStringExtra(ExtraPinFingerprint).orEmpty(),
                publicKeyPin = publicKeyPin,
            )
        }
        identityHost = runCatching { Uri.parse(imageOrigin).host.orEmpty() }.getOrDefault("")
        material = vault.load(imageOrigin)
        appUrl = target

        buildUi(appName, nodeName, dark)
        if (material == null) {
            // No credential is a state this screen can explain; staying silent here
            // is how the old client turned "the key is gone" into a blank page.
            showFailure(getString(R.string.pair_gateway_trouble))
            return
        }
        web.loadUrl(appUrl)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (web.canGoBack()) {
                    web.goBack()
                } else {
                    finish()
                }
            }
        })
    }

    private fun buildUi(appName: String, nodeName: String, dark: Boolean) {
        val background = if (dark) Color.parseColor("#141414") else Color.parseColor("#FAFAFA")
        val elevated = if (dark) Color.parseColor("#1E1E1E") else Color.WHITE
        val primary = if (dark) Color.parseColor("#E8E8E8") else Color.parseColor("#1A1A1A")
        val secondary = if (dark) Color.parseColor("#A0A0A0") else Color.parseColor("#6B6B6B")

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(elevated)
            setPadding(dp(16), dp(10), dp(8), dp(10))
        }
        val title = TextView(this).apply {
            text = appName
            setTextColor(primary)
            textSize = 16f
        }
        val subtitle = TextView(this).apply {
            text = nodeName
            setTextColor(secondary)
            textSize = 12f
            setPadding(dp(8), 0, 0, 0)
        }
        val reload = actionButton("⟳", primary) { web.reload() }
        val close = actionButton("✕", primary) { finish() }
        bar.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(subtitle)
        bar.addView(reload)
        bar.addView(close)

        container = FrameLayout(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(background)
            addView(bar)
            addView(container, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)
        web = createWebView(dark, background)
        container.addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun actionButton(label: String, color: Int, onClick: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            setTextColor(color)
            textSize = 18f
            setPadding(dp(12), 0, dp(12), 0)
            setOnClickListener { onClick() }
        }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    @Suppress("SetJavaScriptEnabled")
    private fun createWebView(dark: Boolean, background: Int): WebView {
        val view = WebView(this)
        view.setBackgroundColor(background)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // Applications such as video conferences play on their own; requiring a
            // gesture here is what made them look broken.
            mediaPlaybackRequiresUserGesture = false
            useWideViewPort = true
            loadWithOverviewMode = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = true
        }
        // The theme already refuses algorithmic darkening (themes.xml
        // forceDarkAllowed=false): the page's own dark styles are what apply.
        if (BuildConfig.DEBUG) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        view.webViewClient = GatewayWebViewClient()
        view.webChromeClient = GatewayChromeClient()
        return view
    }

    private fun allowedHost(host: String): Boolean =
        host == identityHost || host.endsWith("." + identityHost)

    private inner class GatewayChromeClient : android.webkit.WebChromeClient() {

        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message): Boolean {
            if (popup != null) return false
            // A popup opens in a WebView of its own, in the same view tree: window.open
            // is how a good part of the web behaves, and ignoring it looks like a
            // broken page.
            val created = createWebView(true, Color.TRANSPARENT)
            created.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            container.addView(created)
            popup = created
            val transport = resultMsg.obj as WebView.WebViewTransport
            transport.webView = created
            resultMsg.sendToTarget()
            return true
        }

        override fun onCloseWindow(window: WebView) {
            if (window === popup) {
                container.removeView(window)
                window.destroy()
                popup = null
            }
        }
    }

    private inner class GatewayWebViewClient : WebViewClient() {

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val host = request.url.host.orEmpty()
            if (allowedHost(host)) return false
            // Anything that leaves the gateway goes to the system browser: this
            // WebView carries a device certificate, and it is not for other sites.
            runCatching { startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
            return true
        }

        override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
            val identity = material
            if (identity == null) {
                // Never answer a challenge with cancel while an identity is expected:
                // the kernel remembers a negative answer per host and port, and the
                // page then fails forever without saying why. The failure page is
                // already shown in that case.
                return
            }
            if (!allowedHost(request.host.orEmpty())) {
                request.cancel()
                return
            }
            request.proceed(identity.privateKey, identity.chain.toTypedArray())
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) {
            val pin = serverPin
            val host = error.url?.let { runCatching { Uri.parse(it).host }.getOrNull() }.orEmpty()
            val certificate = certificateOf(error)
            if (pin != null && certificate != null && allowedHost(host) && matchesPin(certificate, pin)) {
                // A LAN gateway's certificate is self-signed on purpose; the pin the
                // invitation carried is what stands in for an authority here.
                handler.proceed()
                return
            }
            handler.cancel()
            showFailure(getString(R.string.web_load_failed))
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            crashCount += 1
            view.destroy()
            if (crashCount <= 2) {
                web = createWebView(true, Color.TRANSPARENT)
                container.addView(web)
                web.loadUrl(appUrl)
            } else {
                showFailure(getString(R.string.web_load_failed))
            }
            // True: this Activity handled it. False would let the platform kill the
            // whole process, which is what happens when a WebView's renderer dies.
            return true
        }
    }

    private fun certificateOf(error: android.net.http.SslError): X509Certificate? = try {
        // The certificate the platform refused, in the only form a WebView offers it.
        val state = android.net.http.SslCertificate.saveState(error.certificate)
        val bytes = state.getByteArray("x509-certificate") ?: return null
        CertificateFactory.getInstance("X.509").generateCertificate(bytes.inputStream()) as? X509Certificate
    } catch (e: Exception) {
        null
    }

    private fun matchesPin(certificate: X509Certificate, pin: ServerPin): Boolean {
        val publicKeyPin = Digest.publicKeyPin(certificate)
        val fingerprint = Digest.fingerprint(certificate)
        return publicKeyPin == pin.publicKeyPin || fingerprint == pin.certFingerprint
    }

    private fun showFailure(message: String) {
        container.removeAllViews()
        val view = TextView(this).apply {
            text = message
            textSize = 16f
            gravity = android.view.Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        container.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    override fun onDestroy() {
        popup?.let { container.removeView(it); it.destroy() }
        popup = null
        if (::web.isInitialized) {
            container.removeView(web)
            web.destroy()
        }
        super.onDestroy()
    }

    companion object {
        private const val ExtraUrl = "url"
        private const val ExtraIdentityOrigin = "identityOrigin"
        private const val ExtraAppName = "appName"
        private const val ExtraNodeName = "nodeName"
        private const val ExtraPinFingerprint = "pinFingerprint"
        private const val ExtraPinPublicKey = "pinPublicKey"
        private const val ExtraDark = "dark"

        fun intent(
            context: Context,
            url: String,
            identityOrigin: String,
            appName: String,
            nodeName: String,
            serverPin: ServerPin?,
            dark: Boolean,
        ): Intent = Intent(context, AppWebActivity::class.java)
            .putExtra(ExtraUrl, url)
            .putExtra(ExtraIdentityOrigin, identityOrigin)
            .putExtra(ExtraAppName, appName)
            .putExtra(ExtraNodeName, nodeName)
            .putExtra(ExtraPinFingerprint, serverPin?.certFingerprint)
            .putExtra(ExtraPinPublicKey, serverPin?.publicKeyPin)
            .putExtra(ExtraDark, dark)
    }
}
