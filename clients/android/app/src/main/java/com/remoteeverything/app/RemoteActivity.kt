package com.remoteeverything.app

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.util.Base64InputStream
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.webkit.PermissionRequest
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.remoteeverything.app.web.RemoteBlobDownload
import com.remoteeverything.app.web.RemoteDownloadRequest
import com.remoteeverything.app.web.RemoteWebViewFactory
import com.remoteeverything.app.web.RemoteWebViewCallbacks
import com.remoteeverything.app.web.WebHostPolicy
import com.remoteeverything.app.web.WebIsolationPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File

/**
 * 远程网页使用独立的原生 Activity。
 *
 * 目录和设置继续使用 Compose；网页本身直接挂到系统窗口，避免 Navigation/AnimatedContent
 * 对 AndroidView 的触摸分发、焦点和生命周期造成干扰。一个 Activity 始终只拥有一个
 * WebView，应用切换时完整销毁旧页面。
 */
class RemoteActivity : ComponentActivity() {
    private lateinit var settings: SettingsStore
    private lateinit var config: ConnectionConfig
    private lateinit var appId: String
    private lateinit var appName: String
    private lateinit var openUrl: String
    private var webView: WebView? = null
    private var pageRoot: RemoteFrameLayout? = null
    private var popupView: WebView? = null
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var clientIdentity: ClientIdentity? = null
    private var controls: Dialog? = null
    private var pageGeneration = 0
    private var immersive = false
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var pendingPermission: PendingPermission? = null
    private var pendingSave: PendingSave? = null
    private var preparingBlob = false
    private var saveInProgress = false
    private val webViewsBeingDestroyed = mutableSetOf<WebView>()
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private data class PendingPermission(
        val request: PermissionRequest,
        val resources: List<String>,
    )

    private data class PendingSave(
        val fileName: String,
        val mimeType: String,
        val source: SaveSource,
    )

    private sealed interface SaveSource {
        data class Remote(
            val url: String,
            val identity: ClientIdentity?,
            val headers: Map<String, String>,
        ) : SaveSource

        data class Blob(val file: File) : SaveSource
    }

    private val fileChooserLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val callback = fileChooserCallback ?: return@registerForActivityResult
        fileChooserCallback = null
        val selected = if (result.resultCode == Activity.RESULT_OK) {
            validateSelectedFiles(WebChromeClient.FileChooserParams.parseResult(result.resultCode, result.data))
        } else {
            null
        }
        callback.onReceiveValue(selected)
    }

    private val saveFileLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val save = pendingSave ?: return@registerForActivityResult
        pendingSave = null
        val destination = if (result.resultCode == Activity.RESULT_OK) result.data?.data else null
        if (destination == null) {
            cleanupSave(save)
        } else {
            writeSave(save, destination)
        }
    }

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val pending = pendingPermission ?: return@registerForActivityResult
        pendingPermission = null
        val granted = pending.resources.filter { resource ->
            val permission = androidPermissionFor(resource) ?: return@filter false
            ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        }
        if (granted.isEmpty()) pending.request.deny() else pending.request.grant(granted.toTypedArray())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = SettingsStore(this)
        val launch = runCatching { readLaunch() }.getOrElse {
            finishWithMessage(it.message ?: "远程页面参数无效")
            return
        }
        config = launch.config
        appId = launch.appId
        appName = launch.appName
        openUrl = launch.openUrl
        requestedOrientation = settings.resolveOrientation(config.installationId, appId)
        applyImmersive(true)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    customView != null -> hideCustomView()
                    controls?.isShowing == true -> controls?.dismiss()
                    else -> showControls()
                }
            }
        })
        openPage()
    }

    private data class Launch(
        val config: ConnectionConfig,
        val appId: String,
        val appName: String,
        val openUrl: String,
    )

    private fun readLaunch(): Launch {
        val active = requireNotNull(settings.activeProfile()) { "活动连接不存在" }
        val id = requireNotNull(intent.getStringExtra(EXTRA_APP_ID)).trim()
        val name = requireNotNull(intent.getStringExtra(EXTRA_APP_NAME)).trim()
        val url = requireNotNull(intent.getStringExtra(EXTRA_OPEN_URL)).trim()
        require(APP_ID.matches(id)) { "应用标识无效" }
        require(name.isNotEmpty() && name.codePointCount(0, name.length) <= 80) { "应用名称无效" }
        require(active.isGatewayUrl(url)) { "远程页面地址无效" }
        return Launch(active, id, name, url)
    }

    private fun openPage() {
        val generation = ++pageGeneration
        destroyPage()
        val identity = DeviceIdentity(this)
        val clientIdentity = if (config.mode == "public") identity.clientIdentity(config.installationId) else null
        if (config.mode == "public" && clientIdentity == null) {
            showFailure("设备身份不存在，请重新初始化连接")
            return
        }
        this.clientIdentity = clientIdentity

        val root = RemoteFrameLayout(this).apply {
            setBackgroundColor(palette().background)
            onEdgeSwipe = ::showControls
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            showFailure("当前 Android System WebView 不支持应用隔离，请先更新 Android System WebView 或 Chrome")
            return
        }
        pageRoot = root
        val profileName = WebIsolationPolicy.profileName(config.installationId, appId)
        val browser = runCatching {
            RemoteWebViewFactory.create(
                context = this,
                config = config,
                identity = clientIdentity,
                profileName = profileName,
                displayMode = settings.resolveDisplayMode(config.installationId, appId),
                callbacks = RemoteWebViewCallbacks(
                    onExternal = ::openExternal,
                    onCertificateFailure = {
                        Toast.makeText(this, "服务器证书验证失败，已阻止连接", Toast.LENGTH_LONG).show()
                    },
                    onRendererGone = {
                        if (generation == pageGeneration) showFailure("网页内核异常退出")
                    },
                    onProgress = { _, _ -> },
                    onMainDocumentError = { _, detail ->
                        if (generation == pageGeneration) showFailure(detail)
                    },
                    onFileChooser = ::showFileChooser,
                    onPermissionRequest = ::handlePermissionRequest,
                    onPermissionRequestCanceled = ::handlePermissionCanceled,
                    onDownload = ::beginRemoteDownload,
                    onBlobDownload = ::beginBlobDownload,
                    onPopupCreated = { popup -> showPopup(generation, popup) },
                    onPopupClosed = ::closePopup,
                    onShowCustomView = ::showCustomView,
                    onHideCustomView = { hideCustomView(notifyPage = false) },
                    onHostError = ::showHostError,
                ),
            )
        }.getOrElse {
            showFailure(it.message ?: "网页环境初始化失败")
            return
        }
        webView = browser
        browser.apply {
            isFocusable = true
            isFocusableInTouchMode = true
            isClickable = true
            resumeTimers()
        }
        root.addView(
            browser,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        setContentView(root)
        browser.requestFocus(View.FOCUS_DOWN)
        applyGestureExclusion(root)
        pointRouteAndLoad(browser, profileName, generation)
    }

    @android.annotation.SuppressLint("RequiresFeature")
    private fun pointRouteAndLoad(browser: WebView, profileName: String, generation: Int) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            showFailure("当前网页内核不支持应用隔离")
            return
        }
        val manager = runCatching { WebViewCompat.getProfile(browser).cookieManager }.getOrElse {
            showFailure("无法访问 $profileName 的网页存储")
            return
        }
        manager.setAcceptCookie(true)
        try {
            manager.setCookie(config.gatewayOrigin, WebIsolationPolicy.routingCookie(appId)) { accepted ->
                if (generation != pageGeneration || browser !== webView) return@setCookie
                if (accepted != true) {
                    runOnUiThread { showFailure("应用路由 Cookie 写入失败") }
                    return@setCookie
                }
                runCatching { manager.flush() }
                runOnUiThread {
                    if (generation != pageGeneration || browser !== webView) return@runOnUiThread
                    browser.onResume()
                    browser.loadUrl(openUrl, mapOf("Cache-Control" to "no-cache"))
                }
            }
        } catch (error: Throwable) {
            showFailure("应用路由 Cookie 写入失败：${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun openExternal(uri: Uri) {
        if (!WebHostPolicy.allowsExternalIntent(uri.toString())) {
            showHostError("已阻止不受信任的外部地址")
            return
        }
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) }
            .onFailure { showHostError("没有可打开该链接的应用") }
    }

    private fun showFileChooser(
        callback: ValueCallback<Array<Uri>>,
        params: WebChromeClient.FileChooserParams,
    ): Boolean {
        fileChooserCallback?.onReceiveValue(null)
        fileChooserCallback = callback
        val launched = runCatching {
            val picker = params.createIntent().apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) {
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
            }
            fileChooserLauncher.launch(Intent.createChooser(picker, params.title ?: "选择文件"))
        }.isSuccess
        if (!launched) {
            fileChooserCallback = null
            callback.onReceiveValue(null)
            showHostError("没有可用的系统文件选择器")
        }
        return true
    }

    private fun validateSelectedFiles(values: Array<Uri>?): Array<Uri>? {
        val selected = values.orEmpty().distinctBy(Uri::toString)
        if (selected.isEmpty() || selected.size > WebHostPolicy.MAX_FILE_SELECTIONS) {
            if (selected.size > WebHostPolicy.MAX_FILE_SELECTIONS) showHostError("一次最多选择 ${WebHostPolicy.MAX_FILE_SELECTIONS} 个文件")
            return null
        }
        val valid = selected.all { uri ->
            WebHostPolicy.allowsSelectedFileScheme(uri.scheme) &&
                uri.authority != "$packageName.updates" &&
                runCatching { contentResolver.openInputStream(uri)?.use { true } == true }.getOrDefault(false)
        }
        if (!valid) {
            showHostError("系统文件选择器返回了不可读取的文件")
            return null
        }
        return selected.toTypedArray()
    }

    private fun handlePermissionRequest(request: PermissionRequest) {
        if (!config.isGatewayUri(request.origin)) {
            request.deny()
            return
        }
        pendingPermission?.request?.deny()
        pendingPermission = null
        val supported = request.resources.orEmpty().filter { androidPermissionFor(it) != null }.distinct()
        if (supported.isEmpty()) {
            request.deny()
            return
        }
        val missing = supported.mapNotNull(::androidPermissionFor).distinct().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            request.grant(supported.toTypedArray())
            return
        }
        pendingPermission = PendingPermission(request, supported)
        permissionLauncher.launch(missing.toTypedArray())
    }

    private fun handlePermissionCanceled(request: PermissionRequest) {
        if (pendingPermission?.request === request) pendingPermission = null
    }

    private fun androidPermissionFor(resource: String): String? = when (resource) {
        PermissionRequest.RESOURCE_AUDIO_CAPTURE -> Manifest.permission.RECORD_AUDIO
        PermissionRequest.RESOURCE_VIDEO_CAPTURE -> Manifest.permission.CAMERA
        else -> null
    }

    @android.annotation.SuppressLint("RequiresFeature")
    private fun beginRemoteDownload(browser: WebView, request: RemoteDownloadRequest) {
        if (downloadBusy()) {
            showHostError("已有文件正在准备或保存")
            return
        }
        if (!config.isGatewayUrl(request.url)) {
            showHostError("已阻止不受信任的下载地址")
            return
        }
        val mimeType = WebHostPolicy.normalizeMimeType(request.mimeType)
        val fileName = WebHostPolicy.sanitizeDownloadName(
            URLUtil.guessFileName(request.url, request.contentDisposition, mimeType),
        )
        val headers = linkedMapOf<String, String>()
        request.userAgent?.takeIf(String::isNotBlank)?.let { headers["User-Agent"] = it }
        browser.url?.takeIf(config::isGatewayUrl)?.let { headers["Referer"] = it }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            runCatching { WebViewCompat.getProfile(browser).cookieManager.getCookie(request.url) }
                .getOrNull()
                ?.takeIf(String::isNotBlank)
                ?.let { headers["Cookie"] = it }
        }
        launchSavePicker(
            PendingSave(
                fileName = fileName,
                mimeType = mimeType,
                source = SaveSource.Remote(request.url, clientIdentity, headers),
            ),
        )
    }

    private fun beginBlobDownload(download: RemoteBlobDownload) {
        if (downloadBusy()) {
            showHostError("已有文件正在准备或保存")
            return
        }
        if (!WebHostPolicy.base64PayloadCanFit(download.base64)) {
            showHostError("导出文件超过 16 MiB 限制")
            return
        }
        preparingBlob = true
        ioScope.launch {
            var temporary: File? = null
            var handedToPicker = false
            try {
                val directory = File(cacheDir, "web-downloads")
                check(directory.exists() || directory.mkdirs()) { "无法创建导出缓存" }
                val file = File.createTempFile("download-", ".tmp", directory)
                temporary = file
                var written = 0L
                Base64InputStream(
                    ByteArrayInputStream(download.base64.toByteArray(Charsets.US_ASCII)),
                    Base64.DEFAULT,
                ).use { input ->
                    file.outputStream().buffered().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            written += count
                            check(written <= WebHostPolicy.MAX_BLOB_BYTES) { "导出文件超过 16 MiB 限制" }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                withContext(Dispatchers.Main) {
                    preparingBlob = false
                    if (isFinishing || isDestroyed) return@withContext
                    launchSavePicker(
                        PendingSave(
                            fileName = WebHostPolicy.sanitizeDownloadName(download.fileName),
                            mimeType = WebHostPolicy.normalizeMimeType(download.mimeType),
                            source = SaveSource.Blob(file),
                        ),
                    )
                    handedToPicker = true
                }
            } catch (error: Throwable) {
                withContext(Dispatchers.Main) {
                    preparingBlob = false
                    if (!isFinishing && !isDestroyed) showHostError(error.message ?: "无法准备网页导出文件")
                }
            } finally {
                if (!handedToPicker) temporary?.delete()
            }
        }
    }

    private fun launchSavePicker(save: PendingSave) {
        if (pendingSave != null || saveInProgress) {
            cleanupSave(save)
            showHostError("已有文件正在保存")
            return
        }
        pendingSave = save
        val launched = runCatching {
            saveFileLauncher.launch(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = save.mimeType
                    putExtra(Intent.EXTRA_TITLE, save.fileName)
                },
            )
        }.isSuccess
        if (!launched) {
            pendingSave = null
            cleanupSave(save)
            showHostError("没有可用的系统文件保存器")
        }
    }

    private fun writeSave(save: PendingSave, destination: Uri) {
        saveInProgress = true
        ioScope.launch {
            val failure = try {
                runCatching {
                    val output = requireNotNull(contentResolver.openOutputStream(destination, "w")) { "无法写入所选位置" }
                    output.use { sink ->
                        when (val source = save.source) {
                            is SaveSource.Remote -> SecureHttp.download(
                                config = config,
                                url = source.url,
                                identity = source.identity,
                                headers = source.headers,
                                output = sink,
                            )
                            is SaveSource.Blob -> source.file.inputStream().buffered().use { it.copyTo(sink) }
                        }
                    }
                }.exceptionOrNull()
            } finally {
                cleanupSave(save)
            }
            withContext(Dispatchers.Main) {
                saveInProgress = false
                if (!isFinishing && !isDestroyed) {
                    Toast.makeText(
                        this@RemoteActivity,
                        failure?.let { "保存失败：${it.message ?: it.javaClass.simpleName}" } ?: "文件已保存",
                        if (failure == null) Toast.LENGTH_SHORT else Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }
    }

    private fun downloadBusy(): Boolean = preparingBlob || pendingSave != null || saveInProgress

    private fun cleanupSave(save: PendingSave) {
        (save.source as? SaveSource.Blob)?.file?.delete()
    }

    private fun showPopup(generation: Int, popup: WebView) {
        if (generation != pageGeneration || isFinishing || isDestroyed) {
            destroyWebView(popup, pauseTimers = false)
            return
        }
        closePopup()
        val root = pageRoot
        if (root == null) {
            destroyWebView(popup, pauseTimers = false)
            return
        }
        popupView = popup
        popup.apply {
            isFocusable = true
            isFocusableInTouchMode = true
            isClickable = true
            onResume()
        }
        root.addView(
            popup,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        popup.requestFocus(View.FOCUS_DOWN)
    }

    private fun closePopup(target: WebView? = popupView) {
        val popup = target ?: return
        if (popup === popupView) {
            popupView = null
            hideCustomView()
        }
        destroyWebView(popup, pauseTimers = false)
    }

    private fun showCustomView(view: View, callback: WebChromeClient.CustomViewCallback) {
        if (customView != null) {
            callback.onCustomViewHidden()
            return
        }
        val root = pageRoot
        if (root == null) {
            callback.onCustomViewHidden()
            return
        }
        (view.parent as? ViewGroup)?.removeView(view)
        customView = view
        customViewCallback = callback
        root.addView(
            view,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        view.requestFocus()
        applyImmersive(true)
    }

    private fun hideCustomView(notifyPage: Boolean = true) {
        val view = customView ?: return
        val callback = customViewCallback
        customView = null
        customViewCallback = null
        (view.parent as? ViewGroup)?.removeView(view)
        if (notifyPage) runCatching { callback?.onCustomViewHidden() }
    }

    private fun showHostError(message: String) {
        runOnUiThread {
            if (!isFinishing && !isDestroyed) Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    private fun showControls() {
        if (isFinishing || isDestroyed || controls?.isShowing == true) return
        val colors = palette()
        val dialog = Dialog(this).also { controls = it }
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(22), dp(24), dp(30))
            background = GradientDrawable().apply {
                cornerRadii = floatArrayOf(dp(24f), dp(24f), dp(24f), dp(24f), 0f, 0f, 0f, 0f)
                setColor(colors.background)
            }
        }
        panel.addView(label(appName, 24f, true, colors))
        panel.addView(space(18))
        addChoices(
            panel = panel,
            title = "屏幕方向",
            options = listOf("global" to "跟随全局", "system" to "跟随系统", "portrait" to "竖屏", "landscape" to "横屏"),
            selected = settings.appOrientation(config.installationId, appId),
        ) { value ->
            settings.setAppOrientation(config.installationId, appId, value)
            requestedOrientation = settings.resolveOrientation(config.installationId, appId)
        }
        panel.addView(space(16))
        addChoices(
            panel = panel,
            title = "显示模式",
            options = listOf("global" to "跟随全局", "phone" to "手机", "desktop" to "电脑"),
            selected = settings.appDisplayMode(config.installationId, appId),
        ) { value ->
            if (value != settings.appDisplayMode(config.installationId, appId)) {
                settings.setAppDisplayMode(config.installationId, appId, value)
                dialog.dismiss()
                openPage()
            }
        }
        panel.addView(space(18))
        panel.addView(actionButton("重新加载页面", primary = false, colors = colors) {
            dialog.dismiss()
            openPage()
        })
        if (popupView != null) {
            panel.addView(space(10))
            panel.addView(actionButton("关闭弹出页面", primary = false, colors = colors) {
                dialog.dismiss()
                closePopup()
            })
        }
        panel.addView(space(10))
        panel.addView(actionButton("返回目录", primary = true, colors = colors) {
            dialog.dismiss()
            finish()
        })
        dialog.setContentView(ScrollView(this).apply { addView(panel) })
        dialog.setOnDismissListener { if (controls === dialog) controls = null }
        dialog.window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setGravity(Gravity.BOTTOM)
            clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        }
        dialog.show()
        dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    private fun addChoices(
        panel: LinearLayout,
        title: String,
        options: List<Pair<String, String>>,
        selected: String,
        onSelected: (String) -> Unit,
    ) {
        val colors = palette()
        panel.addView(label(title, 13f, true, colors).apply { setTextColor(colors.muted) })
        val group = RadioGroup(this).apply { orientation = RadioGroup.VERTICAL }
        options.forEach { (value, text) ->
            group.addView(RadioButton(this).apply {
                id = View.generateViewId()
                tag = value
                this.text = text
                textSize = 16f
                setTextColor(colors.text)
                buttonTintList = ColorStateList(
                    arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
                    intArrayOf(colors.primary, colors.muted),
                )
                isChecked = value == selected
                setPadding(0, dp(3), 0, dp(3))
            })
        }
        group.setOnCheckedChangeListener { view, checkedId ->
            val value = view.findViewById<RadioButton>(checkedId)?.tag as? String ?: return@setOnCheckedChangeListener
            onSelected(value)
        }
        panel.addView(group)
    }

    private fun actionButton(text: String, primary: Boolean, colors: NativePalette = palette(), onClick: () -> Unit): Button = Button(this).apply {
        this.text = text
        textSize = 16f
        isAllCaps = false
        setTextColor(if (primary) colors.onPrimary else colors.text)
        background = GradientDrawable().apply {
            cornerRadius = dp(14f)
            setColor(if (primary) colors.primary else colors.surfaceVariant)
            if (!primary) setStroke(dp(1), colors.outline)
        }
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52))
        setOnClickListener { onClick() }
    }

    private fun showFailure(detail: String) {
        ++pageGeneration
        destroyPage()
        val colors = palette()
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(28), dp(40), dp(28), dp(40))
            setBackgroundColor(colors.background)
        }
        panel.addView(label("远程页面没有成功打开", 22f, true, colors).apply { gravity = Gravity.CENTER })
        panel.addView(space(10))
        panel.addView(label(detail, 14f, false, colors).apply {
            gravity = Gravity.CENTER
            setTextColor(colors.muted)
        })
        panel.addView(space(24))
        panel.addView(actionButton("重试", primary = true, colors = colors, onClick = ::openPage))
        panel.addView(space(10))
        panel.addView(actionButton("返回目录", primary = false, colors = colors, onClick = ::finish))
        setContentView(panel)
    }

    private fun label(text: String, size: Float, bold: Boolean, colors: NativePalette = palette()) = TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(colors.text)
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
    }

    private data class NativePalette(
        val background: Int,
        val surfaceVariant: Int,
        val text: Int,
        val muted: Int,
        val outline: Int,
        val primary: Int,
        val onPrimary: Int,
    )

    private fun palette(): NativePalette {
        val dark = when (settings.themeMode()) {
            "light" -> false
            "dark" -> true
            else -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        }
        return if (dark) {
            NativePalette(
                background = Color.rgb(12, 10, 9),
                surfaceVariant = Color.rgb(28, 25, 23),
                text = Color.rgb(245, 245, 244),
                muted = Color.rgb(168, 162, 158),
                outline = Color.rgb(68, 64, 60),
                primary = Color.rgb(251, 191, 36),
                onPrimary = Color.rgb(69, 26, 3),
            )
        } else {
            NativePalette(
                background = Color.rgb(250, 250, 249),
                surfaceVariant = Color.rgb(245, 245, 244),
                text = Color.rgb(28, 25, 23),
                muted = Color.rgb(120, 113, 108),
                outline = Color.rgb(214, 211, 209),
                primary = Color.rgb(180, 83, 9),
                onPrimary = Color.WHITE,
            )
        }
    }

    private fun space(height: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(1, dp(height))
    }

    private fun destroyPage() {
        fileChooserCallback?.onReceiveValue(null)
        fileChooserCallback = null
        pendingPermission?.request?.deny()
        pendingPermission = null
        hideCustomView()
        closePopup()
        pageRoot = null
        val browser = webView ?: return
        webView = null
        destroyWebView(browser, pauseTimers = true)
    }

    private fun destroyWebView(browser: WebView, pauseTimers: Boolean) {
        if (!webViewsBeingDestroyed.add(browser)) return
        try {
            runCatching { browser.stopLoading() }
            runCatching { browser.loadUrl("about:blank") }
            runCatching { browser.onPause() }
            if (pauseTimers) runCatching { browser.pauseTimers() }
            (browser.parent as? ViewGroup)?.removeView(browser)
            runCatching { browser.destroy() }
        } finally {
            webViewsBeingDestroyed.remove(browser)
        }
    }

    private fun finishWithMessage(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        finish()
    }

    private fun applyImmersive(enabled: Boolean) {
        immersive = enabled
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (enabled) hide(WindowInsetsCompat.Type.systemBars()) else show(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun onResume() {
        super.onResume()
        webView?.apply { resumeTimers(); onResume() }
        popupView?.onResume()
        if (immersive) applyImmersive(true)
    }

    override fun onPause() {
        popupView?.onPause()
        webView?.onPause()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && immersive) applyImmersive(true)
    }

    override fun onDestroy() {
        controls?.dismiss()
        controls = null
        ++pageGeneration
        destroyPage()
        pendingSave?.let(::cleanupSave)
        pendingSave = null
        ioScope.cancel()
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()
    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    private fun applyGestureExclusion(view: View) {
        view.post {
            if (view.width == 0 || view.height == 0) return@post
            val edge = dp(28)
            val half = dp(100)
            val centerY = view.height / 2
            ViewCompat.setSystemGestureExclusionRects(
                view,
                listOf(Rect(view.width - edge, (centerY - half).coerceAtLeast(0), view.width, (centerY + half).coerceAtMost(view.height))),
            )
        }
    }

    companion object {
        private const val EXTRA_APP_ID = "app_id"
        private const val EXTRA_APP_NAME = "app_name"
        private const val EXTRA_OPEN_URL = "open_url"
        private val APP_ID = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")

        fun intent(context: Context, app: RemoteApp): Intent = Intent(context, RemoteActivity::class.java).apply {
            putExtra(EXTRA_APP_ID, app.id)
            putExtra(EXTRA_APP_NAME, app.name)
            putExtra(EXTRA_OPEN_URL, app.openUrl)
        }
    }
}

/** 只在触点从右边缘向内形成明确水平拖动后拦截，边缘点击和纵向滚动仍交给网页。 */
private class RemoteFrameLayout(context: Context) : FrameLayout(context) {
    var onEdgeSwipe: (() -> Unit)? = null
    private val edge = 28 * resources.displayMetrics.density
    private val threshold = 56 * resources.displayMetrics.density
    private var tracking = false
    private var intercepting = false
    private var triggered = false
    private var downX = 0f
    private var downY = 0f

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                tracking = event.x >= width - edge
                intercepting = false
                triggered = false
                downX = event.x
                downY = event.y
            }
            MotionEvent.ACTION_MOVE -> if (tracking) {
                val inward = downX - event.x
                val vertical = kotlin.math.abs(event.y - downY)
                if (inward > threshold && inward > vertical * 1.25f) {
                    intercepting = true
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> tracking = false
        }
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!intercepting) return super.onTouchEvent(event)
        if (!triggered) {
            triggered = true
            performClick()
        }
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            tracking = false
            intercepting = false
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        onEdgeSwipe?.invoke()
        return true
    }
}
