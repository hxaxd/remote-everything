package com.remoteeverything.app.web

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.R
import com.remoteeverything.core.api.GatewayClients
import com.remoteeverything.core.identity.AndroidKeyStoreIdentityVault
import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.model.ServerPin
import com.remoteeverything.core.store.SettingsStore
import com.remoteeverything.core.store.WebAppPrefs
import com.remoteeverything.core.store.WebOrientation
import com.remoteeverything.core.store.WebUserAgent
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * One application, on its own origin, in a WebView of its own — a plain view
 * tree in a dedicated activity, because a WebView inside a navigating Compose
 * screen loses touches, focus and its own lifecycle. The identity is resolved
 * before the first navigation: the certificate challenge arrives on the network
 * thread and can only be answered synchronously, so by the time it does, the
 * key is already in memory.
 *
 * The screen belongs to the page: no title bar, no system bars, and everything
 * a chrome would carry waits behind the back gesture in [WebPanelView] — how
 * the screen is held, how the page introduces itself, a reload, and the way
 * out. Those two choices are per application and outlive the visit.
 */
class AppWebActivity : ComponentActivity() {

    private lateinit var web: WebView
    private lateinit var container: FrameLayout
    private lateinit var palette: WebPalette
    private var progressBar: ProgressBar? = null
    private var panel: WebPanelView? = null
    private var popup: WebView? = null
    private var material: Pkcs12.Material? = null
    private var identityOrigin: String = ""
    private var identityHost: String = ""
    private var serverPin: ServerPin? = null
    private var appUrl: String = ""
    private var appKey: String = ""
    private var crashCount: Int = 0
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var fileChooserCallback: android.webkit.ValueCallback<Array<Uri>>? = null
    private var pendingCaptureUri: Uri? = null
    private var pendingWebPermission: PermissionRequest? = null
    private var pendingGeolocation: Pair<String, GeolocationPermissions.Callback>? = null
    private var downloads: WebDownloadBridge? = null
    /** This application's panel choices, as they stand right now. */
    private var prefs: WebAppPrefs = WebAppPrefs()

    private val dark: Boolean get() = intent.getBooleanExtra(ExtraDark, false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(ExtraUrl) ?: run { finish(); return }
        identityOrigin = intent.getStringExtra(ExtraIdentityOrigin) ?: run { finish(); return }
        appKey = intent.getStringExtra(ExtraAppKey) ?: run { finish(); return }
        val pinFingerprint = intent.getStringExtra(ExtraPinFingerprint)
        val pinPublicKey = intent.getStringExtra(ExtraPinPublicKey)
        appUrl = url
        serverPin = if (pinFingerprint != null && pinPublicKey != null) {
            ServerPin(certFingerprint = pinFingerprint, publicKeyPin = pinPublicKey)
        } else null
        identityHost = Uri.parse(identityOrigin).host.orEmpty()
        palette = WebPalette(dark)
        goFullscreen()
        buildUi()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // The way back opens this application's panel first — the same
                // gesture in every other app is a menu, and here it is where the
                // page's own settings live. Leaving is the panel's decision, not
                // the gesture's.
                val overlay = panel
                when {
                    customView != null -> hideVideoFullscreen()
                    overlay != null && overlay.visible -> overlay.hide()
                    popup != null -> closePopup(popup)
                    overlay != null -> overlay.show()
                    else -> finish()
                }
            }
        })

        val vault = AndroidKeyStoreIdentityVault()
        material = vault.load(identityOrigin)
        if (material == null) {
            // No credential is a state this screen can explain; staying silent here
            // is how the old client turned "the key is gone" into a blank page.
            showFailure(getString(R.string.pair_gateway_trouble))
            return
        }
        downloads = WebDownloadBridge(
            context = this,
            clientProvider = {
                material?.let { runCatching { GatewayClients.rawTransport(identityOrigin, it, serverPin) }.getOrNull() }
            },
        )
        lifecycleScope.launch {
            prefs = runCatching { SettingsStore(this@AppWebActivity).webAppPrefs(appKey) }.getOrDefault(WebAppPrefs())
            applyOrientation(prefs.orientation)
            createWebView()
            panel = WebPanelView(
                host = this@AppWebActivity,
                palette = palette,
                initial = prefs,
                onOrientation = { chosen ->
                    prefs = prefs.copy(orientation = chosen)
                    applyOrientation(chosen)
                    persistPrefs()
                },
                onUserAgent = { chosen ->
                    prefs = prefs.copy(userAgent = chosen)
                    applyUserAgent(chosen, reload = true)
                    persistPrefs()
                },
                onRefresh = { reloadPage() },
                onExit = { finish() },
            )
            panel?.let { container.addView(it.root, matchParent()) }
            applyUserAgent(prefs.userAgent, reload = false)
            web.loadUrl(appUrl)
        }
    }

    // --- the screen ------------------------------------------------------------

    private fun goFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        hideSystemBars()
    }

    private fun hideSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Coming back to this screen is coming back to the page, not to the bars.
        if (hasFocus) hideSystemBars()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // A turn does not rebuild this screen — the page keeps its state — so the
        // bars are hidden again here instead of waiting for the next focus change.
        hideSystemBars()
    }

    private fun buildUi() {
        container = FrameLayout(this).apply { setBackgroundColor(palette.background) }
        val pBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
            visibility = View.VISIBLE
        }
        progressBar = pBar
        container.addView(pBar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)))
        // Fullscreen is the layout; the keyboard is the one thing that still has to
        // move the page, and it arrives as an inset rather than as a resize.
        ViewCompat.setOnApplyWindowInsetsListener(container) { view, insets ->
            view.setPadding(0, 0, 0, insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
            insets
        }
        setContentView(container)
    }

    private fun matchParent(): FrameLayout.LayoutParams =
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)

    /**
     * A choice is written even if the screen is being left in the same breath: the
     * write is not the screen's work to abandon.
     */
    private fun persistPrefs() {
        val chosen = prefs
        lifecycleScope.launch {
            withContext(NonCancellable) {
                runCatching { SettingsStore(this@AppWebActivity).setWebAppPrefs(appKey, chosen) }
            }
        }
    }

    private fun applyOrientation(orientation: WebOrientation) {
        requestedOrientation = when (orientation) {
            WebOrientation.SYSTEM -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            WebOrientation.PORTRAIT -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            WebOrientation.LANDSCAPE -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
    }

    private fun applyUserAgent(mode: WebUserAgent, reload: Boolean) {
        val mobile = WebSettings.getDefaultUserAgent(this)
        val agent = when (mode) {
            WebUserAgent.MOBILE -> mobile
            WebUserAgent.DESKTOP -> desktopUserAgent(mobile)
        }
        if (::web.isInitialized) {
            web.settings.userAgentString = agent
            if (reload) reloadPage()
        }
    }

    /**
     * The page is loaded again, rather than reloaded. `reload()` re-issues the
     * navigation with the headers that navigation was made with, so a freshly
     * chosen identity would only show up on the *next* load — which is what made
     * the choice look like it applied itself seconds later. Loading the address
     * is the same page, read again, now.
     */
    private fun reloadPage() {
        if (!::web.isInitialized) return
        progressBar?.visibility = View.VISIBLE
        web.loadUrl(web.url ?: appUrl)
    }

    /**
     * A page that asks for a desktop is asking for a desktop: the mobile token
     * goes, Android becomes a Linux desktop, the engine and its version stay —
     * they are the truth about what is rendering.
     */
    private fun desktopUserAgent(mobile: String): String {
        val engine = Regex("""AppleWebKit/[\d.]+""").find(mobile)?.value ?: "AppleWebKit/537.36"
        val chrome = Regex("""Chrome/[\d.]+""").find(mobile)?.value
            ?: return mobile.replace("Mobile ", "")
        return "Mozilla/5.0 (X11; Linux x86_64) $engine (KHTML, like Gecko) $chrome Safari/537.36"
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    // --- the web view ----------------------------------------------------------

    @Suppress("SetJavaScriptEnabled")
    private fun createWebView() {
        val view = newWebView()
        web = view
        container.addView(view, matchParent())
    }

    private fun newWebView(): WebView {
        val view = WebView(this)
        view.setBackgroundColor(palette.background)
        view.settings.apply {
            javaScriptEnabled = true
            // The pages here come from the network only; file and content
            // schemes have no business in an application view.
            allowFileAccess = false
            allowContentAccess = false
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
        view.setDownloadListener { url, userAgent, contentDisposition, mimetype, _ ->
            // A saved file tells the phone where it went, and saying that in the
            // shade is a permission: asked here, where the reason is on screen.
            requestNotificationPermission()
            downloads?.onDownload(view, url, userAgent, contentDisposition, mimetype)
        }
        downloads?.let { view.addJavascriptInterface(it.blobBridge, "RemoteEverythingBlob") }
        return view
    }

    // Which hosts may ask for the device certificate: the gateway's own host
    // and anything under it. Deliberately any depth — a public gateway serves
    // each application at `<app>.<node>.<gateway host>`, two labels below the
    // origin the device paired with — and deliberately nothing else, so the
    // credential never rides on a host outside the gateway's namespace.
    private fun allowedHost(host: String): Boolean =
        host == identityHost || host.endsWith("." + identityHost)

    private inner class GatewayChromeClient : WebChromeClient() {

        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message): Boolean {
            if (popup != null) return false
            // A popup opens in a WebView of its own, in the same view tree: window.open
            // is how a good part of the web behaves, and ignoring it looks like a
            // broken page.
            val created = newWebView()
            created.setBackgroundColor(Color.TRANSPARENT)
            created.layoutParams = matchParent()
            container.addView(created)
            popup = created
            val transport = resultMsg.obj as WebView.WebViewTransport
            transport.webView = created
            resultMsg.sendToTarget()
            return true
        }

        override fun onCloseWindow(window: WebView) {
            closePopup(window)
        }

        override fun onShowFileChooser(
            view: WebView,
            callback: android.webkit.ValueCallback<Array<Uri>>,
            params: FileChooserParams,
        ): Boolean {
            fileChooserCallback?.onReceiveValue(null)
            fileChooserCallback = callback
            return runCatching { fileChooserLauncher.launch(chooserIntent(params)) }
                .onFailure { fileChooserCallback = null }
                .isSuccess
        }

        /** A page asks for the camera or the microphone: the system's own question comes first. */
        override fun onPermissionRequest(request: PermissionRequest) {
            val wanted = request.resources.filter {
                it == PermissionRequest.RESOURCE_VIDEO_CAPTURE || it == PermissionRequest.RESOURCE_AUDIO_CAPTURE
            }
            if (wanted.isEmpty()) {
                request.deny()
                return
            }
            val needed = wanted.mapNotNull { resource ->
                when (resource) {
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE -> Manifest.permission.CAMERA
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE -> Manifest.permission.RECORD_AUDIO
                    else -> null
                }
            }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (needed.isEmpty()) {
                request.grant(wanted.toTypedArray())
            } else {
                pendingWebPermission = request
                webPermissionLauncher.launch(needed.toTypedArray())
            }
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            if (pendingWebPermission === request) pendingWebPermission = null
        }

        /** A page asks where it is: granted once the platform permission is actually there. */
        override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: GeolocationPermissions.Callback?) {
            if (origin == null || callback == null) return
            val needed = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (needed.isEmpty()) {
                callback.invoke(origin, true, false)
            } else {
                pendingGeolocation = origin to callback
                locationPermissionLauncher.launch(needed.toTypedArray())
            }
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (customView != null) {
                callback.onCustomViewHidden()
                return
            }
            customView = view
            customViewCallback = callback
            panel?.hide()
            container.addView(view, matchParent())
            hideSystemBars()
        }

        override fun onHideCustomView() {
            hideVideoFullscreen()
        }
    }

    private fun hideVideoFullscreen() {
        val view = customView ?: return
        container.removeView(view)
        customView = null
        customViewCallback?.onCustomViewHidden()
        customViewCallback = null
    }

    private fun closePopup(window: WebView?) {
        if (window != null && window === popup) {
            container.removeView(window)
            window.destroy()
            popup = null
        }
    }

    // --- what the page may ask the system for ------------------------------------

    /** One chooser that is the page's own: files, or a fresh picture. */
    private fun chooserIntent(params: WebChromeClient.FileChooserParams): Intent {
        val accepted = params.acceptTypes.filter { it.isNotBlank() }
        val content = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (accepted.isNotEmpty()) putExtra(Intent.EXTRA_MIME_TYPES, accepted.toTypedArray())
            if (params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) {
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        val chooser = Intent.createChooser(content, getString(R.string.web_choose_file))
        val capture = captureIntent(accepted)
        if (capture != null) chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(capture))
        return chooser
    }

    /** A page that accepts an image gets the camera offered beside the files. */
    private fun captureIntent(accepted: List<String>): Intent? {
        val wantsImage = accepted.isEmpty() || accepted.any { it == "*/*" || it.startsWith("image/") }
        if (!wantsImage) return null
        return runCatching {
            val directory = File(cacheDir, "uploads").apply { mkdirs() }
            val photo = File(directory, "capture-${System.currentTimeMillis()}.jpg")
            val uri = FileProvider.getUriForFile(this, "$packageName.webfiles", photo)
            pendingCaptureUri = uri
            Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
        }.getOrNull()
    }

    private val fileChooserLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val callback = fileChooserCallback ?: return@registerForActivityResult
            fileChooserCallback = null
            val capture = pendingCaptureUri
            pendingCaptureUri = null
            // A cancelled chooser is a page told nothing was chosen — never the
            // capture URI, which no camera has written to in that case. A capture
            // that did happen answers with no data: the picture is the URI it was
            // told to write to.
            val chosen = if (result.resultCode == android.app.Activity.RESULT_OK) {
                WebChromeClient.FileChooserParams.parseResult(result.resultCode, result.data)
                    ?: capture?.let { arrayOf(it) }
            } else null
            callback.onReceiveValue(chosen)
        }

    private val webPermissionLauncher: ActivityResultLauncher<Array<String>> =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            val request = pendingWebPermission ?: return@registerForActivityResult
            pendingWebPermission = null
            if (grants.values.all { it }) request.grant(request.resources) else request.deny()
        }

    private val locationPermissionLauncher: ActivityResultLauncher<Array<String>> =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            val pending = pendingGeolocation ?: return@registerForActivityResult
            pendingGeolocation = null
            pending.second.invoke(pending.first, grants.values.any { it }, false)
        }

    /**
     * The receipt for a download is a notification, and drawing one is a
     * permission the person has to give. A refusal is not a dead end: the file is
     * still saved, and the toast still says where.
     */
    private fun requestNotificationPermission() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) return
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return
        runCatching { notificationPermissionLauncher.launch(permission) }
    }

    private val notificationPermissionLauncher: ActivityResultLauncher<String> =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    // --- navigation ------------------------------------------------------------

    private inner class GatewayWebViewClient : WebViewClient() {

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            super.onPageStarted(view, url, favicon)
            progressBar?.visibility = View.VISIBLE
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            super.onPageFinished(view, url)
            progressBar?.visibility = View.GONE
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val host = request.url.host.orEmpty()
            if (allowedHost(host)) return false
            // Anything that leaves the gateway goes to the system browser: this
            // WebView carries a device certificate, and it is not for other sites.
            runCatching { startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
            return true
        }

        override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
            certHandler.handle(request)
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) {
            pinningClient.handleSslError(
                handler = handler,
                error = error,
                onSuccess = {},
                onFailure = { showFailure(getString(R.string.web_load_failed)) }
            )
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            crashCount += 1
            container.removeView(view)
            view.destroy()
            if (crashCount <= 2) {
                createWebView()
                web.loadUrl(appUrl)
            } else {
                showFailure(getString(R.string.web_load_failed))
            }
            return true
        }
    }

    private val certHandler by lazy {
        WebClientCertHandler(
            materialProvider = { material },
            isAllowedHost = ::allowedHost
        )
    }

    private val pinningClient by lazy {
        WebPinningClient(
            pinProvider = { serverPin },
            isAllowedHost = ::allowedHost
        )
    }

    private fun showFailure(message: String) {
        progressBar?.visibility = View.GONE
        panel?.let { container.removeView(it.root) }
        if (::web.isInitialized) container.removeView(web)
        val errorView = WebErrorView.create(
            context = this,
            message = message,
            dark = dark,
            onRetry = {
                container.removeAllViews()
                val pBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                    isIndeterminate = true
                    visibility = View.VISIBLE
                }
                progressBar = pBar
                container.addView(pBar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)))
                createWebView()
                panel?.let { container.addView(it.root, matchParent()) }
                web.loadUrl(appUrl)
            },
            onClose = { finish() }
        )
        container.addView(errorView)
    }

    override fun onDestroy() {
        closePopup(popup)
        hideVideoFullscreen()
        if (::web.isInitialized) {
            container.removeView(web)
            web.destroy()
        }
        super.onDestroy()
    }

    companion object {
        private const val ExtraUrl = "url"
        private const val ExtraIdentityOrigin = "identityOrigin"
        private const val ExtraAppKey = "appKey"
        private const val ExtraPinFingerprint = "pinFingerprint"
        private const val ExtraPinPublicKey = "pinPublicKey"
        private const val ExtraDark = "dark"

        /**
         * @param appKey which application this is, as `nodeId/appId`: what its
         * panel choices are remembered against.
         */
        fun intent(
            context: Context,
            url: String,
            identityOrigin: String,
            appKey: String,
            serverPin: ServerPin?,
            dark: Boolean,
        ): Intent = Intent(context, AppWebActivity::class.java)
            .putExtra(ExtraUrl, url)
            .putExtra(ExtraIdentityOrigin, identityOrigin)
            .putExtra(ExtraAppKey, appKey)
            .putExtra(ExtraPinFingerprint, serverPin?.certFingerprint)
            .putExtra(ExtraPinPublicKey, serverPin?.publicKeyPin)
            .putExtra(ExtraDark, dark)
    }
}
