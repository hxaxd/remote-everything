package com.agentremote.app

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
    private var webView: WebView? = null
    private var remoteRoot: EdgeSwipeFrameLayout? = null
    private var remoteMenu: View? = null
    private var selectedApp: RemoteApp? = null
    private var screenGeneration = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (selectedApp != null) {
                    if (remoteRoot == null) {
                        showCatalog()
                    } else if (remoteMenu == null) {
                        showRemoteMenu()
                    } else {
                        hideRemoteMenu()
                    }
                } else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
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

    private fun showStartupFailure(error: Throwable) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(64), dp(28), dp(32))
            setBackgroundColor(Color.rgb(2, 6, 23))
        }
        root.addView(label("Agent 远程", 30f, Color.WHITE, Typeface.BOLD))
        root.addView(label("启动失败，但应用没有退出", 18f, Color.rgb(248, 113, 113), Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, dp(10))
        })
        root.addView(label(error.message ?: error.javaClass.simpleName, 14f, Color.rgb(203, 213, 225)).apply {
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(24))
        })
        root.addView(Button(this).apply {
            text = "重新启动"
            setOnClickListener { recreate() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)))
        setContentView(ScrollView(this).apply { addView(root) })
    }

    private fun showEnrollment() {
        screenGeneration += 1
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(52), dp(28), dp(32))
            setBackgroundColor(Color.rgb(2, 6, 23))
        }
        root.addView(label("Agent 远程", 31f, Color.WHITE, Typeface.BOLD))
        root.addView(label("安全连接这台设备", 16f, Color.rgb(148, 163, 184)).apply { setPadding(0, dp(10), 0, dp(34)) })
        val progress = ProgressBar(this)
        root.addView(progress, LinearLayout.LayoutParams(dp(34), dp(34)))
        val status = label("正在生成设备身份并申请注册…", 15f, Color.rgb(203, 213, 225)).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(22), 0, dp(12))
        }
        root.addView(status, matchWrap())
        val code = label("", 36f, Color.rgb(96, 165, 250), Typeface.BOLD).apply {
            letterSpacing = 0.14f
            gravity = Gravity.CENTER
            typeface = Typeface.MONOSPACE
            visibility = View.GONE
            setPadding(0, dp(14), 0, dp(16))
        }
        root.addView(code, matchWrap())
        val copy = Button(this).apply {
            text = "复制审批码"
            visibility = View.GONE
            setOnClickListener {
                (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(ClipData.newPlainText("Agent 远程审批码", code.text))
                Toast.makeText(this@MainActivity, "审批码已复制", Toast.LENGTH_SHORT).show()
            }
        }
        root.addView(copy, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)).apply { topMargin = dp(6) })
        root.addView(label("把审批码发给服务端管理员。批准前无法访问远程电脑；设备身份由本机系统密钥加密保存。", 13f, Color.rgb(100, 116, 139)).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, 0)
        })
        setContentView(ScrollView(this).apply { addView(root) })

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
                    status.setTextColor(Color.rgb(248, 113, 113))
                }
            }
        }
    }

    private fun showCatalog() {
        screenGeneration += 1
        val generation = screenGeneration
        selectedApp = null
        remoteMenu = null
        remoteRoot = null
        runCatching { webView?.destroy() }
        webView = null
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(54), dp(22), dp(36))
            setBackgroundColor(Color.rgb(2, 6, 23))
        }
        content.addView(label("Agent 远程", 32f, Color.WHITE, Typeface.BOLD))
        content.addView(label("我的应用", 16f, Color.rgb(148, 163, 184)).apply { setPadding(0, dp(7), 0, dp(28)) })
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(ProgressBar(this@MainActivity).apply { isIndeterminate = true }, LinearLayout.LayoutParams(dp(34), dp(34)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        content.addView(body, matchWrap())
        setContentView(ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(Color.rgb(2, 6, 23))
            addView(content)
        })
        loadCatalog(body, generation)
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
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(17))
            background = rounded(Color.rgb(15, 23, 42), 20f, Color.rgb(30, 41, 59))
        }
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val accent = runCatching { Color.parseColor(app.accent) }.getOrDefault(Color.rgb(37, 99, 235))
        header.addView(label(app.icon.take(4), 21f, Color.WHITE, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            background = rounded(accent, 15f)
        }, LinearLayout.LayoutParams(dp(52), dp(52)))
        val names = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), 0, 0, 0) }
        names.addView(label(app.name, 19f, Color.WHITE, Typeface.BOLD))
        names.addView(label(statusText(app.code), 13f, statusColor(app.code)).apply { setPadding(0, dp(4), 0, 0) })
        header.addView(names, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        card.addView(header, matchWrap())
        if (app.description.isNotBlank()) {
            card.addView(label(app.description, 14f, Color.rgb(148, 163, 184)).apply { setPadding(0, dp(15), 0, dp(15)) }, matchWrap())
        }
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val power = Button(this).apply {
            text = if (app.code == "stopped") "启动" else "停止"
            isEnabled = app.code == "ready" || app.code == "stopped"
            setOnClickListener {
                isEnabled = false
                controlApp(app, if (app.code == "stopped") "start" else "stop", body, generation)
            }
        }
        val enter = Button(this).apply {
            text = "进入"
            isEnabled = validWebUrl(app.webUrl)
            setOnClickListener { showRemote(app) }
        }
        actions.addView(power, LinearLayout.LayoutParams(0, dp(48), 1f).apply { rightMargin = dp(8) })
        actions.addView(enter, LinearLayout.LayoutParams(0, dp(48), 1f).apply { leftMargin = dp(8) })
        card.addView(actions, matchWrap())
        return card.apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(14) }
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
        remoteMenu = null
        val root = EdgeSwipeFrameLayout(this).apply {
            setBackgroundColor(Color.rgb(2, 6, 23))
            onEdgeSwipe = { showRemoteMenu() }
        }.also { remoteRoot = it }
        val browser = WebView(this).also { webView = it }
        browser.setBackgroundColor(Color.rgb(2, 6, 23))
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
        setContentView(root)
        browser.loadUrl(app.webUrl)
    }

    private fun showRemoteMenu() {
        val root = remoteRoot ?: return
        if (remoteMenu != null) return
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(145, 0, 0, 0))
            isClickable = true
            setOnClickListener { hideRemoteMenu() }
        }
        val drawer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(58), dp(24), dp(28))
            setBackgroundColor(Color.rgb(15, 23, 42))
            isClickable = true
            setOnClickListener { }
            addView(label("选项", 26f, Color.WHITE, Typeface.BOLD))
            addView(Button(this@MainActivity).apply {
                text = "返回目录"
                setOnClickListener { showCatalog() }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)).apply { topMargin = dp(32) })
        }
        overlay.addView(
            drawer,
            FrameLayout.LayoutParams(
                minOf(dp(300), resources.displayMetrics.widthPixels - dp(48)),
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
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(64), dp(28), dp(32))
            setBackgroundColor(Color.rgb(2, 6, 23))
        }
        root.addView(label(app.name, 28f, Color.WHITE, Typeface.BOLD))
        root.addView(label("远程页面没有成功打开", 18f, Color.rgb(248, 113, 113), Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, dp(10))
        })
        root.addView(label(detail, 14f, Color.rgb(203, 213, 225)).apply {
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(24))
        })
        root.addView(Button(this).apply {
            text = "重试"
            setOnClickListener { showRemote(app) }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)).apply { bottomMargin = dp(10) })
        root.addView(Button(this).apply {
            text = "返回目录"
            setOnClickListener { showCatalog() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(50)))
        setContentView(ScrollView(this).apply { addView(root) })
    }

    private fun validWebUrl(value: String): Boolean {
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return false
        return uri.scheme == "https" && uri.host == AppConfig.GATEWAY_HOST
    }

    private fun messageCard(title: String, detail: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(22), dp(20), dp(22))
        background = rounded(Color.rgb(15, 23, 42), 20f, Color.rgb(30, 41, 59))
        addView(label(title, 18f, Color.WHITE, Typeface.BOLD))
        addView(label(detail, 14f, Color.rgb(148, 163, 184)).apply { setPadding(0, dp(8), 0, 0) })
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
        "ready" -> Color.rgb(134, 239, 172)
        "starting", "stopping", "stopped" -> Color.rgb(253, 186, 116)
        "computer_offline" -> Color.rgb(148, 163, 184)
        else -> Color.rgb(248, 113, 113)
    }

    private fun label(text: String, size: Float, color: Int, style: Int = Typeface.NORMAL) = TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(color)
        setTypeface(typeface, style)
    }

    private fun rounded(color: Int, radiusDp: Float, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(color)
        cornerRadius = dp(radiusDp.toInt()).toFloat()
        if (stroke != null) setStroke(dp(1), stroke)
    }

    private fun matchWrap() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    override fun onDestroy() {
        alive.set(false)
        screenGeneration += 1
        main.removeCallbacksAndMessages(null)
        runCatching { webView?.destroy() }
        executor.shutdownNow()
        super.onDestroy()
    }
}
