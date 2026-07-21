package com.remoteeverything.app.web

import android.content.ComponentCallbacks2
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.WebView
import com.remoteeverything.app.ClientIdentity
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.RemoteApp
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 远程应用 WebView 预热缓存池。
 *
 * 生命周期规则(避免"隐藏页被 Chromium 节流导致 SPA 启动卡死"):
 * - [warm] 在目录成功后创建并加载页面,预热 TLS/HTTP 缓存/渲染进程;
 * - 首次 [acquire] 一律重载一次(走 HTTP 缓存,极快),让 SPA 在可见状态全速完成启动;
 * - 之后短时间内返回直接续上;离开超过 [HIDDEN_RELOAD_MS] 或页面加载失败则重建/重载;
 * - attach/detach 严格配对 onResume/onPause 与定时器暂停恢复。
 *
 * 所有方法必须在主线程调用。
 */
class WebViewPool(
    private val context: Context,
    private val onExternal: (Uri) -> Unit,
    private val onCertificateFailure: () -> Unit,
    private val displayModeResolver: (String) -> String,
) {
    class Entry internal constructor(
        val appId: String,
        val webView: WebView,
        val displayMode: String,
        internal val progressFlow: MutableStateFlow<Int>,
    ) {
        val progress = progressFlow.asStateFlow()
        internal val failedFlow = MutableStateFlow<String?>(null)
        val failed = failedFlow.asStateFlow()
        internal var lastUsed: Long = 0L
        internal var detachedAt: Long = 0L
        internal var viewedAfterLoad = false
        val loaded: Boolean get() = progressFlow.value >= 100 && failedFlow.value == null
    }

    private val main = Handler(Looper.getMainLooper())
    private val entries = LinkedHashMap<String, Entry>()
    private var config: ConnectionConfig? = null
    private var identity: ClientIdentity? = null
    private var warmToken = 0

    /** 渲染进程死亡等导致条目被销毁时的通知(参数为 appId)。 */
    var onEntryGone: ((String) -> Unit)? = null

    /** 绑定会话;连接变化时清空旧缓存。 */
    fun configure(config: ConnectionConfig, identity: ClientIdentity?) {
        val current = this.config
        if (current != null && current.installationId == config.installationId && current.gatewayOrigin == config.gatewayOrigin) return
        destroyAll()
        this.config = config
        this.identity = identity
    }

    /** 目录成功后预热:显示模式已变化的条目先作废,缺失的条目逐个(间隔约 800ms)创建并加载。 */
    fun warm(apps: List<RemoteApp>) {
        val session = config ?: return
        entries.values
            .filter { it.displayMode != displayModeResolver(it.appId) }
            .forEach { invalidate(it.appId) }
        warmToken += 1
        val token = warmToken
        apps.filter { it.code == "ready" && it.id !in entries }.forEachIndexed { index, app ->
            main.postDelayed({
                if (token != warmToken || this.config !== session) return@postDelayed
                createEntry(app)
                evictIfNeeded()
            }, 800L * (index + 1))
        }
    }

    /** 进入应用:命中缓存直接返回;失败条目重建;首次进入重载预热页。 */
    fun acquire(app: RemoteApp): Entry {
        val existing = entries[app.id]
        if (existing != null) {
            if (existing.failedFlow.value != null) {
                // 预热加载失败(如应用尚未就绪):销毁重建,立即可见加载
                invalidate(app.id)
                val fresh = createEntry(app)
                fresh.viewedAfterLoad = true
                evictIfNeeded()
                return fresh
            }
            existing.lastUsed = System.nanoTime()
            resume(existing)
            val hiddenTooLong = existing.detachedAt > 0L &&
                System.currentTimeMillis() - existing.detachedAt > HIDDEN_RELOAD_MS
            if (!existing.viewedAfterLoad || hiddenTooLong) {
                // 首次进入:重载预热页,让 SPA 在可见状态全速启动(走缓存,极快);
                // 隐藏过久:页面已被系统节流,重载恢复(走缓存)
                existing.progressFlow.value = 0
                existing.webView.reload()
            }
            existing.viewedAfterLoad = true
            existing.detachedAt = 0L
            return existing
        }
        val entry = createEntry(app)
        entry.viewedAfterLoad = true
        evictIfNeeded()
        return entry
    }

    fun entry(appId: String): Entry? = entries[appId]

    /** 离开应用界面:只从视图树卸载并暂停,保留页面状态。 */
    fun release(appId: String) {
        val entry = entries[appId] ?: return
        pause(entry)
    }

    /** 按条目卸载:界面重组时旧条目可能已被替换,只摘自身视图。 */
    fun release(entry: Entry) {
        pause(entry)
    }

    private fun resume(entry: Entry) {
        entry.lastUsed = System.nanoTime()
        entry.webView.onResume()
        entry.webView.resumeTimers()
        entry.webView.invalidate()
    }

    private fun pause(entry: Entry) {
        entry.lastUsed = System.nanoTime()
        entry.detachedAt = System.currentTimeMillis()
        entry.webView.onPause()
        entry.webView.pauseTimers()
        (entry.webView.parent as? ViewGroup)?.removeView(entry.webView)
    }

    /** 已停止应用的缓存页作废(进程已死,页面不可再用),下次进入重新加载。 */
    fun pruneStopped(apps: List<RemoteApp>) {
        val stopped = apps.filter { it.code == "stopped" }.map { it.id }.toSet()
        if (stopped.isEmpty()) return
        stopped.forEach(::invalidate)
    }

    /** 销毁单个条目(如手动重新加载或显示模式变更前)。 */
    fun invalidate(appId: String) {
        entries.remove(appId)?.let(::destroyEntry)
    }

    fun destroyAll() {
        warmToken += 1
        entries.values.forEach(::destroyEntry)
        entries.clear()
    }

    /** 内存紧张时回收未挂载的条目;正在使用的保留。 */
    fun trimMemory(level: Int) {
        if (level < ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        val disposable = entries.values.filter { it.webView.parent == null }
        disposable.forEach {
            entries.remove(it.appId)
            destroyEntry(it)
        }
    }

    private fun createEntry(app: RemoteApp): Entry {
        val session = requireNotNull(config) { "WebViewPool 尚未绑定会话" }
        val progress = MutableStateFlow(0)
        var entryRef: Entry? = null
        val displayMode = displayModeResolver(app.id)
        val webView = RemoteWebViewFactory.create(
            context = context,
            config = session,
            identity = identity,
            displayMode = displayMode,
            onExternal = onExternal,
            onCertificateFailure = onCertificateFailure,
            onRendererGone = { view ->
                val victim = entries.entries.firstOrNull { it.value.webView === view }
                if (victim != null) {
                    entries.remove(victim.key)
                    (view.parent as? ViewGroup)?.removeView(view)
                    runCatching { view.destroy() }
                    onEntryGone?.invoke(victim.key)
                }
            },
            onProgress = { view, value ->
                entryRef?.takeIf { it.webView === view }?.let {
                    it.progressFlow.value = value
                }
            },
            onMainDocumentError = { view, detail ->
                entryRef?.takeIf { it.webView === view }?.let {
                    it.failedFlow.value = detail
                    it.progressFlow.value = 0
                }
            },
        )
        val entry = Entry(app.id, webView, displayMode, progress)
        entryRef = entry
        entry.lastUsed = System.nanoTime()
        entries[app.id] = entry
        webView.loadUrl(app.openUrl)
        return entry
    }

    private fun evictIfNeeded() {
        while (entries.size > MAX_ENTRIES) {
            val victim = entries.values
                .filter { it.webView.parent == null }
                .minByOrNull { it.lastUsed }
                ?: entries.values.minByOrNull { it.lastUsed }
                ?: return
            entries.remove(victim.appId)
            destroyEntry(victim)
        }
    }

    private fun destroyEntry(entry: Entry) {
        (entry.webView.parent as? ViewGroup)?.removeView(entry.webView)
        runCatching { entry.webView.destroy() }
    }

    companion object {
        const val MAX_ENTRIES = 5
        const val HIDDEN_RELOAD_MS = 3 * 60_000L
    }
}
