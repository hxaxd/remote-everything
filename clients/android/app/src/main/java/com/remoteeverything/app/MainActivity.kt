package com.remoteeverything.app

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.net.toUri
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val catalogPoller = CatalogPoller(
        postDelayed = { callback, delay -> main.postDelayed(callback, delay) },
        removeCallbacks = { callback -> main.removeCallbacks(callback) },
    )
    private val executor = Executors.newSingleThreadExecutor()
    private val alive = AtomicBoolean(true)
    private lateinit var identity: DeviceIdentity
    private lateinit var settings: SettingsStore
    private lateinit var setupTransaction: SetupTransaction
    private var connection: ConnectionConfig? = null
    private var webView: WebView? = null
    private var remoteRoot: EdgeSwipeFrameLayout? = null
    private var remoteMenu: View? = null
    private var floatingKeys: FloatingKeysView? = null
    private var selectedApp: RemoteApp? = null
    private var settingsOpen = false
    private var screenGeneration = 0
    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let(::showScannedSetup)
    }

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
            setupTransaction = SetupTransaction(settings, identity, "${Build.MANUFACTURER} ${Build.MODEL} · Android")
            setupTransaction.recover()
            connection = settings.activeProfile()
            enableFullscreen()
            val configured = connection
            if (configured == null || (configured.mode == "public" && !identity.hasCredential(configured.installationId))) {
                showConnectionSetup()
            } else {
                showCatalog()
            }
        }.onFailure(::showStartupFailure)
    }

    private fun enableFullscreen() {
        runCatching {
            WindowCompat.setDecorFitsSystemWindows(window, false)
            WindowInsetsControllerCompat(window, window.decorView).apply {
                hide(WindowInsetsCompat.Type.systemBars())
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    private fun applyOrientation(appId: String?) {
        requestedOrientation = settings.resolveOrientation(connection?.installationId, appId)
    }

    private fun connectionIdentity(config: ConnectionConfig): ClientIdentity? =
        if (config.mode == "public") identity.clientIdentity(config.installationId) else null

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun contentRoot(): LinearLayout = ScreenRenderer.contentRoot(this)

    private fun fullScroll(content: View): ScrollView = ScreenRenderer.fullScroll(this, content)

    private fun showStartupFailure(error: Throwable) {
        val root = contentRoot().apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(72), dp(28), dp(32))
        }
        root.addView(Ui.label(this, "远程万物", 30f, Ui.textPrimary, Typeface.BOLD))
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

    private fun showConnectionSetup() {
        cancelCatalogPolling()
        screenGeneration += 1
        val generation = screenGeneration
        settingsOpen = false
        applyOrientation(null)
        val staged = settings.stagedProfile()?.takeIf { identity.hasStagedCredential(it.installationId) }
        val view = ScreenRenderer.connectionSetup(
            context = this,
            profiles = settings.profiles(),
            staged = staged,
            canOpen = { it.mode != "public" || identity.hasCredential(it.installationId) },
            onScan = { scanLauncher.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("扫描 Remote Everything 初始化二维码").setBeepEnabled(false).setOrientationLocked(false)) },
            onPaste = { value, status, button -> startSetup(value, status, button, generation) },
            onResume = { profile, status, button -> resumePublicActivation(profile, status, button, generation) },
            onOpen = { profile, _ -> settings.setActiveProfile(profile.installationId); connection = profile; showCatalog() },
            onDelete = ::confirmRemoveProfile,
        )
        setContentView(view)
    }

    private fun confirmRemoveProfile(profile: ConnectionConfig) {
        val message = if (profile.mode == "public") {
            "删除本机保存的连接和设备私钥。服务器上的设备记录应由部署 Agent 同时吊销。"
        } else {
            "删除本机保存的连接。"
        }
        AlertDialog.Builder(this)
            .setTitle("删除 ${profile.name}？")
            .setMessage(message)
            .setNegativeButton("取消", null)
            .setPositiveButton("删除") { _, _ ->
                identity.removeCredential(profile.installationId)
                settings.removeProfile(profile.installationId)
                if (connection?.installationId == profile.installationId) connection = null
                showConnectionSetup()
            }
            .show()
    }

    private fun showScannedSetup(value: String) {
        val view = ScreenRenderer.connecting(this) { status, button -> startSetup(value, status, button, screenGeneration) }
        setContentView(view.root)
        startSetup(value, view.status, view.retry, screenGeneration)
    }

    private fun startSetup(value: String, status: TextView, button: Button?, generation: Int) {
        val setup = runCatching { AppConfig.parseSetup(value) }.getOrElse {
            status.setTextColor(Ui.danger)
            status.text = it.message ?: "初始化链接无效"
            return
        }
        button?.isEnabled = false
        status.setTextColor(Ui.textSecondary)
        status.text = if (setup.profile.mode == "public") "正在配对并验证完整链路…" else "正在验证节点证书和应用目录…"
        executor.execute {
            val result = runCatching {
                setupTransaction.connect(setup)
            }
            main.post {
                if (generation != screenGeneration) return@post
                result.onSuccess { configured ->
                    connection = configured
                    showCatalog()
                }.onFailure { error ->
                    button?.isEnabled = true
                    status.setTextColor(Ui.danger)
                    status.text = error.message ?: "连接失败"
                }
            }
        }
    }

    private fun resumePublicActivation(config: ConnectionConfig, status: TextView, button: Button, generation: Int) {
        button.isEnabled = false
        status.setTextColor(Ui.textSecondary)
        status.text = "正在继续验证完整链路…"
        executor.execute {
            val result = runCatching { setupTransaction.activate(config) }
            main.post {
                if (generation != screenGeneration) return@post
                result.onSuccess {
                    connection = it
                    showCatalog()
                }.onFailure {
                    button.isEnabled = true
                    status.setTextColor(Ui.danger)
                    status.text = it.message ?: "激活失败"
                }
            }
        }
    }

    private fun showCatalog() {
        val config = connection ?: run {
            showConnectionSetup()
            return
        }
        if (config.mode == "public" && !identity.hasCredential(config.installationId)) {
            showConnectionSetup()
            return
        }
        cancelCatalogPolling()
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
        val view = ScreenRenderer.catalog(this, ::showSettings)
        setContentView(view.root)
        loadCatalog(view.body, generation, config)
    }

    private fun showSettings() {
        cancelCatalogPolling()
        screenGeneration += 1
        settingsOpen = true
        applyOrientation(null)
        setContentView(ScreenRenderer.settings(
            context = this,
            store = settings,
            configured = connection,
            onBack = ::showCatalog,
            onOrientation = { value -> settings.setGlobalOrientation(value); applyOrientation(null); showSettings() },
            onConnections = { connection = null; showConnectionSetup() },
        ))
    }

    private fun sectionLabel(text: String): View = ScreenRenderer.sectionLabel(this, text)

    private fun optionRow(options: List<Pair<String, String>>, current: String, onSelect: (String) -> Unit): View =
        ScreenRenderer.optionRow(this, options, current, onSelect)

    private fun loadCatalog(body: LinearLayout, generation: Int, config: ConnectionConfig) {
        if (!alive.get() || generation != screenGeneration) return
        executor.execute {
            val result = runCatching {
                RemoteApi.catalog(config, connectionIdentity(config))
            }
            main.post {
                if (generation != screenGeneration) return@post
                body.removeAllViews()
                result.onSuccess { snapshot ->
                    if (!snapshot.computerConnected || snapshot.code == "computer_offline") {
                        body.addView(messageCard("节点离线", "服务入口仍可连接，但节点核心当前不可用。应用会自动重试。"))
                    } else if (snapshot.apps.isEmpty()) {
                        body.addView(messageCard("还没有已注册的应用", "在电脑上注册应用后会自动出现在这里。"))
                    } else {
                        snapshot.apps.forEach { body.addView(appCard(it, body, generation, config)) }
                    }
                }.onFailure { error ->
                    val cause = generateSequence(error) { it.cause }.last()
                    val detail = cause.message?.takeIf(String::isNotBlank) ?: cause.javaClass.simpleName
                    body.addView(messageCard("目录暂时不可用", "连接失败：$detail\n\n应用会自动重试。"))
                }
                scheduleCatalogPoll(body, generation, config, 5_000)
            }
        }
    }

    private fun scheduleCatalogPoll(body: LinearLayout, generation: Int, config: ConnectionConfig, delayMillis: Long) {
        catalogPoller.schedule(delayMillis) { loadCatalog(body, generation, config) }
    }

    private fun cancelCatalogPolling() {
        catalogPoller.cancel()
    }

    private fun appCard(app: RemoteApp, body: LinearLayout, generation: Int, config: ConnectionConfig): View {
        return ScreenRenderer.applicationCard(
            context = this,
            app = app,
            canEnter = validWebUrl(app.openUrl, config),
            onPower = { controlApp(app, if (app.code == "stopped") "start" else "stop", body, generation, config) },
            onEnter = { showRemote(app) },
        )
    }

    private fun controlApp(app: RemoteApp, action: String, body: LinearLayout, generation: Int, config: ConnectionConfig) {
        executor.execute {
            val success = runCatching {
                RemoteApi.control(config, connectionIdentity(config), app.id, action)
            }.getOrDefault(false)
            main.post {
                if (!success) Toast.makeText(this, "操作失败，请稍后重试", Toast.LENGTH_SHORT).show()
                if (generation == screenGeneration) scheduleCatalogPoll(body, generation, config, 0)
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun showRemote(app: RemoteApp) {
        val config = connection ?: return
        if (!validWebUrl(app.openUrl, config)) return
        runCatching { openRemote(app, config) }.onFailure { showRemoteFailure(app, it.message ?: it.javaClass.simpleName) }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun openRemote(app: RemoteApp, config: ConnectionConfig) {
        cancelCatalogPolling()
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
        val clientIdentity = connectionIdentity(config)
        val browser = RemoteWebView.create(
            context = this,
            config = config,
            identity = clientIdentity,
            onExternal = { uri -> runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) } },
            onCertificateFailure = { Toast.makeText(this, "服务器证书验证失败，已阻止连接", Toast.LENGTH_LONG).show() },
            onRendererGone = {
                webView = null
                if (generation == screenGeneration) showRemoteFailure(app, "网页内核异常退出")
            },
        ).also { webView = it }
        root.addView(browser, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val keys = FloatingKeysView(this).also { floatingKeys = it }
        keys.onKey = { action -> sendShortcut(action) }
        keys.onMoved = { x, y -> settings.setFkPosition(config.installationId, app.id, x, y) }
        keys.onResized = { scale -> settings.setFkScale(config.installationId, app.id, scale) }
        root.addView(keys, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        keys.applyState(settings.fkX(config.installationId, app.id), settings.fkY(config.installationId, app.id), settings.fkScale(config.installationId, app.id))
        keys.visibility = if (settings.fkVisible(config.installationId, app.id)) View.VISIBLE else View.GONE
        setContentView(root)
        browser.loadUrl(app.openUrl)
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
        val installationId = connection?.installationId ?: return
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
        val currentOrientation = settings.appOrientation(installationId, app.id)
        drawer.addView(optionRow(
            listOf("global" to "跟随全局", "system" to "跟随系统", "portrait" to "竖屏", "landscape" to "横屏"),
            currentOrientation,
        ) { value ->
            settings.setAppOrientation(installationId, app.id, value)
            applyOrientation(app.id)
            hideRemoteMenu()
            showRemoteMenu()
        })
        drawer.addView(View(this), LinearLayout.LayoutParams(1, dp(18)))

        drawer.addView(sectionLabel("悬浮快捷键"))
        val keysVisible = settings.fkVisible(installationId, app.id)
        drawer.addView(optionRow(
            listOf("show" to "显示", "hide" to "隐藏"),
            if (keysVisible) "show" else "hide",
        ) { value ->
            val visible = value == "show"
            settings.setFkVisible(installationId, app.id, visible)
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
        cancelCatalogPolling()
        screenGeneration += 1
        selectedApp = app
        runCatching { webView?.destroy() }
        webView = null
        remoteMenu = null
        remoteRoot = null
        floatingKeys = null
        setContentView(ScreenRenderer.remoteFailure(this, app, detail, { showRemote(app) }, ::showCatalog))
    }

    private fun validWebUrl(value: String, config: ConnectionConfig): Boolean {
        val uri = runCatching { value.toUri() }.getOrNull() ?: return false
        return config.isGatewayUri(uri)
    }

    private fun messageCard(title: String, detail: String): View = ScreenRenderer.messageCard(this, title, detail)

    override fun onDestroy() {
        alive.set(false)
        cancelCatalogPolling()
        screenGeneration += 1
        main.removeCallbacksAndMessages(null)
        runCatching { webView?.destroy() }
        executor.shutdownNow()
        super.onDestroy()
    }
}
