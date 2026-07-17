package com.agentremote.app

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.ClientCertRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class RemoteApp(
    val id: String,
    val name: String,
    val description: String,
    val icon: String,
    val accent: String,
    val webUrl: String,
    val code: String,
)

class EdgeSwipeFrameLayout(context: Context) : FrameLayout(context) {
    var onEdgeSwipe: (() -> Unit)? = null
    private var tracking = false
    private var intercepting = false
    private var direction = 1f
    private var downX = 0f
    private var downY = 0f
    private val edgeWidth = 30f * resources.displayMetrics.density
    private val interceptDistance = 14f * resources.displayMetrics.density
    private val triggerDistance = 72f * resources.displayMetrics.density

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                direction = if (event.x <= edgeWidth) 1f else -1f
                tracking = event.x <= edgeWidth || event.x >= width - edgeWidth
                intercepting = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (tracking) {
                    val horizontal = (event.x - downX) * direction
                    val vertical = kotlin.math.abs(event.y - downY)
                    if (horizontal > interceptDistance && horizontal > vertical * 1.2f) {
                        intercepting = true
                        return true
                    }
                    if (vertical > interceptDistance || horizontal < -interceptDistance) tracking = false
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                tracking = false
                intercepting = false
            }
        }
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!intercepting) return super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            if ((event.x - downX) * direction >= triggerDistance) onEdgeSwipe?.invoke()
            tracking = false
            intercepting = false
        } else if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
            tracking = false
            intercepting = false
        }
        return true
    }
}

class MainActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val alive = AtomicBoolean(true)
    private lateinit var identity: DeviceIdentity
    private lateinit var settings: SettingsStore
    private var webView: WebView? = null
    private var remoteRoot: EdgeSwipeFrameLayout? = null
    private var remoteMenu: View? = null
    private var floatingKeys: FloatingKeysView? = null
    private var selectedApp: RemoteApp? = null
    private var settingsOpen = false
    private var screenGeneration = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = SettingsStore(this)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    settingsOpen -> showCatalog()
                    selectedApp != null -> {
                        if (remoteRoot == null) showCatalog()
                        else if (remoteMenu == null) showRemoteMenu()
                        else hideRemoteMenu()
                    }
                    else -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                    }
                }
            }
        })
        runCatching {
            identity = DeviceIdentity(this)
            enableFullscreen()
            if (identity.isApproved()) showCatalog() else showEnrollment()
        }.onFailure(::showStartupFailure)
    }

    private fun enableFullscreen() {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(false)
                window.insetsController?.let {
                    it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                    it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                }
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                        View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                        View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                        View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    )
            }
        }
    }

    private fun applyOrientation(appId: String?) {
        requestedOrientation = settings.resolveOrientation(appId)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun contentRoot(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Ui.bg)
    }

    private fun fullScroll(content: View): ScrollView = ScrollView(this).apply {
        isFillViewport = true
        setBackgroundColor(Ui.bg)
        addView(content)
    }

    private fun header(title: String, subtitle: String? = null, action: (() -> View)? = null): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titles = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(Ui.label(this, title, 28f, Ui.textPrimary, Typeface.BOLD))
        if (subtitle != null) {
            titles.addView(Ui.label(this, subtitle, 13f, Ui.textSecondary).apply { setPadding(0, dp(4), 0, 0) })
        }
        row.addView(titles, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        action?.let { row.addView(it()) }
        return row
    }

    private fun showStartupFailure(error: Throwable) {
        val root = contentRoot().apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(72), dp(28), dp(32))
        }
        root.addView(Ui.label(this, "Agent 远程", 30f, Ui.textPrimary, Typeface.BOLD))
        root.addView(Ui.label(this, "启动失败，但应用没有退出", 17f, Ui.danger, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, dp(10))
        })
        root.addView(Ui.label(this, error.message ?: error.javaClass.simpleName, 13f, Ui.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(24))
        })
        root.addView(Ui.primaryButton(this, "重新启动").apply {
            setOnClickListener { recreate() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)))
        setContentView(fullScroll(root))
    }

    private fun showEnrollment() {
        screenGeneration += 1
        settingsOpen = false
        applyOrientation(null)
        val root = contentRoot().apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(56), dp(24), dp(32))
        }
        root.addView(Ui.label(this, "Agent 远程", 30f, Ui.textPrimary, Typeface.BOLD))
        root.addView(Ui.label(this, "安全连接这台设备", 15f, Ui.textSecondary).apply { setPadding(0, dp(8), 0, dp(26)) })

        val cardView = Ui.card(this).apply { setPadding(dp(22), dp(24), dp(22), dp(24)) }
        val progress = ProgressBar(this)
        cardView.addView(progress, LinearLayout.LayoutParams(dp(32), dp(32)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        val status = Ui.label(this, "正在生成设备身份并申请注册…", 14f, Ui.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(18), 0, dp(10))
        }
        cardView.addView(status, Ui.matchWrap())
        val code = Ui.label(this, "", 34f, Ui.accentText, Typeface.BOLD).apply {
            letterSpacing = 0.14f
            gravity = Gravity.CENTER
            typeface = Typeface.MONOSPACE
            visibility = View.GONE
            setPadding(0, dp(10), 0, dp(6))
        }
        cardView.addView(code, Ui.matchWrap())
        val copy = Ui.primaryButton(this, "复制审批码").apply {
            visibility = View.GONE
            setOnClickListener {
                (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(ClipData.newPlainText("Agent 远程审批码", code.text))
                Toast.makeText(this@MainActivity, "审批码已复制", Toast.LENGTH_SHORT).show()
            }
        }
        cardView.addView(copy, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(48)).apply { topMargin = dp(10) })
        cardView.addView(
            Ui.label(this, "把审批码发给服务端管理员。批准前无法访问远程电脑；设备身份由本机系统密钥加密保存。", 12f, Ui.textMuted).apply {
                gravity = Gravity.CENTER
                setPadding(0, dp(16), 0, 0)
            },
            Ui.matchWrap(),
        )
        if (!identity.hardwareBacked) {
            cardView.addView(
                Ui.label(this, "当前环境不支持系统密钥库，设备身份以软件方式保存（兼容模式）。", 12f, Ui.warn).apply {
                    gravity = Gravity.CENTER
                    setPadding(0, dp(10), 0, 0)
                },
                Ui.matchWrap(),
            )
        }
        root.addView(cardView, Ui.matchWrap())
        setContentView(fullScroll(root))

        executor.execute {
            try {
                val deviceName = "${Build.MANUFACTURER} ${Build.MODEL} · Android".take(80)
                val proof = identity.createProof(deviceName)
                val credentialPassword = identity.credentialPassword()
                val payload = JSONObject()
                    .put("device_name", deviceName)
                    .put("public_key_pem", identity.publicKeyPem())
                    .put("proof_nonce", proof.nonce)
                    .put("proof_signature", proof.signature)
                    .put("credential_delivery", "pkcs12")
                    .put("credential_password", credentialPassword)
                    .toString()
                val bootstrap = SecureHttp.bootstrapKeyManager(this)
                val response = SecureHttp.request(
                    AppConfig.ENROLL_REQUEST_URL,
                    "POST",
                    bootstrap,
                    mapOf("X-Kimi-Bootstrap-Fingerprint" to AppConfig.BOOTSTRAP_FINGERPRINT),
                    payload,
                )
                require(response.status == 200) { "注册请求失败（${response.status}）" }
                val requested = response.json()
                val requestId = requested.getString("request_id")
                val registrationCode = requested.getString("registration_code")
                main.post {
                    progress.visibility = View.GONE
                    status.text = "等待服务端批准"
                    code.text = registrationCode
                    code.visibility = View.VISIBLE
                    copy.visibility = View.VISIBLE
                }
                while (alive.get()) {
                    val query = AppConfig.ENROLL_STATUS_URL + "?id=" + URLEncoder.encode(requestId, "UTF-8")
                    val polled = SecureHttp.request(
                        query,
                        "GET",
                        bootstrap,
                        mapOf("X-Kimi-Bootstrap-Fingerprint" to AppConfig.BOOTSTRAP_FINGERPRINT),
                    )
                    if (polled.status == 404) {
                        main.post { showEnrollment() }
                        return@execute
                    }
                    if (polled.status == 200) {
                        val result = polled.json()
                        when (result.optString("status")) {
                            "approved" -> {
                                identity.installCredential(result.getString("credential_pkcs12"), credentialPassword)
                                main.post { showCatalog() }
                                return@execute
                            }
                            "rejected", "revoked" -> error("此设备的注册申请已被拒绝")
                        }
                    }
                    Thread.sleep(3_000)
                }
            } catch (error: Throwable) {
                main.post {
                    progress.visibility = View.GONE
                    status.text = "连接失败：${error.message ?: error.javaClass.simpleName}\n\n重新打开应用即可重试。"
                    status.setTextColor(Ui.danger)
                }
            }
        }
    }

    private fun showCatalog() {
        screenGeneration += 1
        val generation = screenGeneration
        selectedApp = null
        settingsOpen = false
        remoteMenu = null
        remoteRoot = null
        floatingKeys = null
        runCatching { webView?.destroy() }
        webView = null
        applyOrientation(null)
        val content = contentRoot().apply { setPadding(dp(20), dp(48), dp(20), dp(32)) }
        content.addView(header("Agent 远程", "我的应用") {
            TextView(this).apply {
                text = "⚙"
                textSize = 22f
                setTextColor(Ui.textSecondary)
                setPadding(dp(10), dp(4), dp(4), dp(4))
                setOnClickListener { showSettings() }
            }
        })
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(24), 0, 0)
        }
        body.addView(ProgressBar(this).apply { isIndeterminate = true }, LinearLayout.LayoutParams(dp(32), dp(32)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        content.addView(body, Ui.matchWrap())
        setContentView(fullScroll(content))
        loadCatalog(body, generation)
    }

    private fun showSettings() {
        screenGeneration += 1
        settingsOpen = true
        applyOrientation(null)
        val content = contentRoot().apply { setPadding(dp(20), dp(48), dp(20), dp(32)) }
        content.addView(header("设置", "全局选项，应用级设置优先于全局") {
            TextView(this).apply {
                text = "‹"
                textSize = 26f
                setTextColor(Ui.textSecondary)
                setPadding(dp(8), 0, dp(10), 0)
                setOnClickListener { showCatalog() }
            }
        })
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(22), 0, 0)
        }
        body.addView(sectionLabel("屏幕方向（全局）"))
        body.addView(optionRow(
            listOf("system" to "跟随系统", "portrait" to "竖屏锁定", "landscape" to "横屏锁定"),
            settings.globalOrientation(),
        ) { value ->
            settings.setGlobalOrientation(value)
            applyOrientation(null)
            showSettings()
        })
        body.addView(
            Ui.label(this, "单个应用的方向可在远程界面的边缘菜单里单独设置，应用级设置优先于此全局项。", 12f, Ui.textMuted).apply {
                setPadding(0, dp(16), 0, 0)
            },
        )
        content.addView(body, Ui.matchWrap())
        setContentView(fullScroll(content))
    }

    private fun sectionLabel(text: String): View = Ui.label(this, text, 13f, Ui.textSecondary, Typeface.BOLD).apply {
        setPadding(0, 0, 0, dp(8))
    }

    private fun optionRow(options: List<Pair<String, String>>, current: String, onSelect: (String) -> Unit): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = Ui.rounded(Ui.card, 16f, Ui.cardBorder)
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        options.forEach { (value, label) ->
            val selected = value == current
            val item = TextView(this).apply {
                text = label
                textSize = 13f
                gravity = Gravity.CENTER
                setTextColor(if (selected) Color.WHITE else Ui.textSecondary)
                if (selected) background = Ui.rounded(Ui.accent, 12f)
                setPadding(0, dp(10), 0, dp(10))
                setOnClickListener { onSelect(value) }
            }
            row.addView(item, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        return row
    }

    private fun loadCatalog(body: LinearLayout, generation: Int) {
        if (!alive.get() || generation != screenGeneration) return
        executor.execute {
            val result = runCatching {
                val response = SecureHttp.request(
                    AppConfig.APPS_URL,
                    "GET",
                    identity.keyManager(),
                    mapOf("Authorization" to "Bearer ${AppConfig.CONTROL_TOKEN}"),
                )
                require(response.status == 200)
                val array = response.json().getJSONArray("apps")
                buildList {
                    for (index in 0 until array.length()) {
                        val value = array.getJSONObject(index)
                        add(RemoteApp(
                            value.getString("id"),
                            value.optString("name", value.getString("id")),
                            value.optString("description"),
                            value.optString("icon", "·"),
                            value.optString("accent", "#2563eb"),
                            value.optString("web_url"),
                            value.optString("code", "unknown"),
                        ))
                    }
                }
            }
            main.post {
                if (generation != screenGeneration) return@post
                body.removeAllViews()
                result.onSuccess { apps ->
                    if (apps.isEmpty()) {
                        body.addView(messageCard("还没有已注册的应用", "在电脑上注册应用后会自动出现在这里。"))
                    } else {
                        apps.forEach { body.addView(appCard(it, body, generation)) }
                    }
                }.onFailure { error ->
                    val cause = generateSequence(error) { it.cause }.last()
                    val detail = cause.message?.takeIf(String::isNotBlank) ?: cause.javaClass.simpleName
                    body.addView(messageCard("目录暂时不可用", "连接失败：$detail\n\n应用会自动重试。"))
                }
                main.postDelayed({ loadCatalog(body, generation) }, 5_000)
            }
        }
    }

    private fun appCard(app: RemoteApp, body: LinearLayout, generation: Int): View {
        val cardView = Ui.card(this).apply { setPadding(dp(16), dp(16), dp(16), dp(16)) }
        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val accent = runCatching { Color.parseColor(app.accent) }.getOrDefault(Ui.accent)
        headerRow.addView(Ui.label(this, app.icon.take(4), 20f, Color.WHITE, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            background = Ui.rounded(accent, 14f)
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        val names = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), 0, 0, 0)
        }
        names.addView(Ui.label(this, app.name, 17f, Ui.textPrimary, Typeface.BOLD))
        names.addView(Ui.label(this, statusText(app.code), 12f, statusColor(app.code)).apply { setPadding(0, dp(3), 0, 0) })
        headerRow.addView(names, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        cardView.addView(headerRow, Ui.matchWrap())
        if (app.description.isNotBlank()) {
            cardView.addView(Ui.label(this, app.description, 13f, Ui.textSecondary).apply { setPadding(0, dp(13), 0, dp(13)) }, Ui.matchWrap())
        }
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val power = Ui.ghostButton(this, if (app.code == "stopped") "启动" else "停止").apply {
            isEnabled = app.code == "ready" || app.code == "stopped"
            setOnClickListener {
                isEnabled = false
                controlApp(app, if (app.code == "stopped") "start" else "stop", body, generation)
            }
        }
        val enter = Ui.primaryButton(this, "进入").apply {
            isEnabled = validWebUrl(app.webUrl)
            setOnClickListener { showRemote(app) }
        }
        actions.addView(power, LinearLayout.LayoutParams(0, dp(46), 1f).apply { rightMargin = dp(7) })
        actions.addView(enter, LinearLayout.LayoutParams(0, dp(46), 1f).apply { leftMargin = dp(7) })
        cardView.addView(actions, Ui.matchWrap())
        return cardView.apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) }
        }
    }

    private fun controlApp(app: RemoteApp, action: String, body: LinearLayout, generation: Int) {
        executor.execute {
            val success = runCatching {
                SecureHttp.request(
                    AppConfig.appActionUrl(app.id, action),
                    "POST",
                    identity.keyManager(),
                    mapOf("Authorization" to "Bearer ${AppConfig.CONTROL_TOKEN}"),
                ).status == 200
            }.getOrDefault(false)
            main.post {
                if (!success) Toast.makeText(this, "操作失败，请稍后重试", Toast.LENGTH_SHORT).show()
                if (generation == screenGeneration) loadCatalog(body, generation)
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun showRemote(app: RemoteApp) {
        if (!validWebUrl(app.webUrl)) return
        runCatching { openRemote(app) }.onFailure { showRemoteFailure(app, it.message ?: it.javaClass.simpleName) }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun openRemote(app: RemoteApp) {
        screenGeneration += 1
        val generation = screenGeneration
        selectedApp = app
        settingsOpen = false
        remoteMenu = null
        applyOrientation(app.id)
        val root = EdgeSwipeFrameLayout(this).apply {
            setBackgroundColor(Ui.bg)
            onEdgeSwipe = { showRemoteMenu() }
        }.also { remoteRoot = it }
        val browser = WebView(this).also { webView = it }
        browser.setBackgroundColor(Ui.bg)
        browser.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = false
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) safeBrowsingEnabled = true
        }
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        browser.webViewClient = object : WebViewClient() {
            override fun onReceivedClientCertRequest(view: WebView?, request: ClientCertRequest) {
                val proceeded = runCatching {
                    if (request.host != AppConfig.GATEWAY_HOST || request.port != 443) return@runCatching false
                    val chain = identity.certificateChain()
                    if (chain.isEmpty()) return@runCatching false
                    request.proceed(identity.privateKey(), chain)
                    true
                }.getOrDefault(false)
                if (!proceeded) request.cancel()
            }

            override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler, error: android.net.http.SslError?) {
                handler.cancel()
                Toast.makeText(this@MainActivity, "服务器证书验证失败，已阻止连接", Toast.LENGTH_LONG).show()
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean {
                val uri = request.url
                if (uri.scheme == "https" && uri.host == AppConfig.GATEWAY_HOST) return false
                runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) }
                return true
            }

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                runCatching { view?.destroy() }
                webView = null
                if (generation == screenGeneration) showRemoteFailure(app, "网页内核异常退出")
                return true
            }
        }
        root.addView(browser, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val keys = FloatingKeysView(this).also { floatingKeys = it }
        keys.onKey = { action -> sendShortcut(action) }
        keys.onMoved = { x, y -> settings.setFkPosition(app.id, x, y) }
        keys.onResized = { scale -> settings.setFkScale(app.id, scale) }
        root.addView(keys, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        keys.applyState(settings.fkX(app.id), settings.fkY(app.id), settings.fkScale(app.id))
        keys.visibility = if (settings.fkVisible(app.id)) View.VISIBLE else View.GONE
        setContentView(root)
        browser.loadUrl(app.webUrl)
    }

    private fun sendShortcut(action: String) {
        val browser = webView ?: return
        val js = when (action) {
            "esc" -> keyJs("Escape", "Escape")
            "tab" -> keyJs("Tab", "Tab")
            "enter" -> keyJs("Enter", "Enter")
            "ctrlc" -> keyJs("c", "KeyC", ctrl = true)
            "paste" -> pasteJs() ?: return
            else -> return
        }
        browser.evaluateJavascript(js, null)
    }

    private fun keyJs(key: String, code: String, ctrl: Boolean = false): String = """
        (function(){
          const el = document.activeElement || document.body;
          ['keydown','keyup'].forEach(t => el.dispatchEvent(new KeyboardEvent(t, {key: '$key', code: '$code', ctrlKey: $ctrl, bubbles: true, cancelable: true})));
        })();
    """.trimIndent()

    private fun pasteJs(): String? {
        val clip = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString() ?: return null
        val encoded = JSONObject.quote(text)
        return """
        (function(){
          const t = $encoded;
          const el = document.activeElement;
          if (!el) return;
          if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
            const s = el.selectionStart || 0, e = el.selectionEnd || s;
            el.value = el.value.slice(0, s) + t + el.value.slice(e);
            el.selectionStart = el.selectionEnd = s + t.length;
            el.dispatchEvent(new Event('input', {bubbles: true}));
          } else if (el.isContentEditable) {
            document.execCommand('insertText', false, t);
          }
        })();
        """.trimIndent()
    }

    private fun showRemoteMenu() {
        val app = selectedApp ?: return
        val root = remoteRoot ?: return
        if (remoteMenu != null) return
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(150, 0, 0, 0))
            isClickable = true
            setOnClickListener { hideRemoteMenu() }
        }
        val drawer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(52), dp(20), dp(24))
            setBackgroundColor(Ui.card)
            isClickable = true
            setOnClickListener { }
        }
        drawer.addView(Ui.label(this, app.name, 22f, Ui.textPrimary, Typeface.BOLD))
        drawer.addView(Ui.label(this, "选项", 13f, Ui.textSecondary).apply { setPadding(0, dp(4), 0, dp(20)) })

        drawer.addView(sectionLabel("屏幕方向（本应用）"))
        val currentOrientation = settings.appOrientation(app.id)
        drawer.addView(optionRow(
            listOf("global" to "跟随全局", "system" to "跟随系统", "portrait" to "竖屏", "landscape" to "横屏"),
            currentOrientation,
        ) { value ->
            settings.setAppOrientation(app.id, value)
            applyOrientation(app.id)
            hideRemoteMenu()
            showRemoteMenu()
        })
        drawer.addView(View(this), LinearLayout.LayoutParams(1, dp(18)))

        drawer.addView(sectionLabel("悬浮快捷键"))
        val keysVisible = settings.fkVisible(app.id)
        drawer.addView(optionRow(
            listOf("show" to "显示", "hide" to "隐藏"),
            if (keysVisible) "show" else "hide",
        ) { value ->
            val visible = value == "show"
            settings.setFkVisible(app.id, visible)
            floatingKeys?.visibility = if (visible) View.VISIBLE else View.GONE
            hideRemoteMenu()
            showRemoteMenu()
        })
        drawer.addView(
            Ui.label(this, "⠿ 拖动移动，◢ 拖动缩放；位置和大小按应用记忆。", 12f, Ui.textMuted).apply {
                setPadding(0, dp(8), 0, 0)
            },
        )
        drawer.addView(View(this), LinearLayout.LayoutParams(1, dp(22)))

        drawer.addView(Ui.primaryButton(this, "返回目录").apply {
            setOnClickListener { showCatalog() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)))
        overlay.addView(
            drawer,
            FrameLayout.LayoutParams(
                minOf(dp(320), resources.displayMetrics.widthPixels - dp(40)),
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.START,
            ),
        )
        remoteMenu = overlay
        root.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun hideRemoteMenu() {
        val menu = remoteMenu ?: return
        remoteRoot?.removeView(menu)
        remoteMenu = null
    }

    private fun showRemoteFailure(app: RemoteApp, detail: String) {
        screenGeneration += 1
        selectedApp = app
        runCatching { webView?.destroy() }
        webView = null
        remoteMenu = null
        remoteRoot = null
        floatingKeys = null
        val root = contentRoot().apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(72), dp(28), dp(32))
        }
        root.addView(Ui.label(this, app.name, 26f, Ui.textPrimary, Typeface.BOLD))
        root.addView(Ui.label(this, "远程页面没有成功打开", 17f, Ui.danger, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(26), 0, dp(10))
        })
        root.addView(Ui.label(this, detail, 13f, Ui.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(24))
        })
        root.addView(Ui.primaryButton(this, "重试").apply {
            setOnClickListener { showRemote(app) }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)).apply { bottomMargin = dp(10) })
        root.addView(Ui.ghostButton(this, "返回目录").apply {
            setOnClickListener { showCatalog() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)))
        setContentView(fullScroll(root))
    }

    private fun validWebUrl(value: String): Boolean {
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return false
        return uri.scheme == "https" && uri.host == AppConfig.GATEWAY_HOST
    }

    private fun messageCard(title: String, detail: String): View = Ui.card(this).apply {
        setPadding(dp(20), dp(20), dp(20), dp(20))
        addView(Ui.label(this@MainActivity, title, 17f, Ui.textPrimary, Typeface.BOLD))
        addView(Ui.label(this@MainActivity, detail, 13f, Ui.textSecondary).apply { setPadding(0, dp(8), 0, 0) })
    }

    private fun statusText(code: String) = when (code) {
        "ready" -> "● 正在运行"
        "starting" -> "● 正在启动"
        "stopping" -> "● 正在停止"
        "stopped" -> "● 已停止"
        "computer_offline" -> "● 电脑离线"
        else -> "● 状态不可用"
    }

    private fun statusColor(code: String) = when (code) {
        "ready" -> Ui.ok
        "starting", "stopping", "stopped" -> Ui.warn
        "computer_offline" -> Ui.textSecondary
        else -> Ui.danger
    }

    override fun onDestroy() {
        alive.set(false)
        screenGeneration += 1
        main.removeCallbacksAndMessages(null)
        runCatching { webView?.destroy() }
        executor.shutdownNow()
        super.onDestroy()
    }
}
