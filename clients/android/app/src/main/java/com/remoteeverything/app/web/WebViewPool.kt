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
 * - 目录加载成功后调用 [warm],后台逐个创建并加载应用页面,进入时秒开;
 * - [acquire]/[release] 只做视图树的挂载/卸载,页面状态完整保留;
 * - 上限 [MAX_ENTRIES],LRU 淘汰;渲染进程死亡、连接切换、内存紧张时回收。
 *
 * 所有方法必须在主线程调用。
 */
class WebViewPool(
    private val context: Context,
    private val onExternal: (Uri) -> Unit,
    private val onCertificateFailure: () -> Unit,
) {
    class Entry internal constructor(
        val appId: String,
        val webView: WebView,
        internal val progressFlow: MutableStateFlow<Int>,
    ) {
        val progress = progressFlow.asStateFlow()
        internal var lastUsed: Long = 0L
        internal var loadedAt: Long = 0L
        internal var viewedAfterLoad = false
        val loaded: Boolean get() = progressFlow.value >= 100
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

    /** 目录成功后预热:缺失的条目逐个(间隔约 800ms)创建并加载。 */
    fun warm(apps: List<RemoteApp>) {
        val session = config ?: return
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

    /** 进入应用:命中缓存直接返回;未命中立即创建加载。超时预热页自动用缓存快速重载。 */
    fun acquire(app: RemoteApp): Entry {
        val existing = entries[app.id]
        if (existing != null) {
            existing.lastUsed = System.nanoTime()
            existing.webView.onResume()
            existing.webView.resumeTimers()
            existing.webView.invalidate()
            if (existing.loaded && !existing.viewedAfterLoad &&
                System.currentTimeMillis() - existing.loadedAt > STALE_AFTER_MS
            ) {
                // 预热页在不可见状态停留过久,SPA 自举可能已被冻结,重载一次(走 HTTP 缓存,很快)
                existing.progressFlow.value = 0
                existing.webView.reload()
            }
            existing.viewedAfterLoad = true
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
        entry.lastUsed = System.nanoTime()
        entry.webView.onPause()
        entry.webView.pauseTimers()
        (entry.webView.parent as? ViewGroup)?.removeView(entry.webView)
    }

    /** 按条目卸载:界面重组时旧条目可能已被替换,只摘自身视图。 */
    fun release(entry: Entry) {
        entry.lastUsed = System.nanoTime()
        entry.webView.onPause()
        entry.webView.pauseTimers()
        (entry.webView.parent as? ViewGroup)?.removeView(entry.webView)
    }

    /** 已停止应用的缓存页作废(进程已死,页面不可再用),下次进入重新加载。 */
    fun pruneStopped(apps: List<RemoteApp>) {
        val stopped = apps.filter { it.code == "stopped" }.map { it.id }.toSet()
        if (stopped.isEmpty()) return
        stopped.forEach { id ->
            entries.remove(id)?.let { victim ->
                (victim.webView.parent as? ViewGroup)?.removeView(victim.webView)
                runCatching { victim.webView.destroy() }
            }
        }
    }

    /** 销毁单个条目(如手动重新加载前)。 */
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
        val webView = RemoteWebViewFactory.create(
            context = context,
            config = session,
            identity = identity,
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
                    if (value >= 100) {
                        it.loadedAt = System.currentTimeMillis()
                        it.viewedAfterLoad = false
                    }
                }
            },
        )
        val entry = Entry(app.id, webView, progress)
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
        const val STALE_AFTER_MS = 90_000L
    }
}
