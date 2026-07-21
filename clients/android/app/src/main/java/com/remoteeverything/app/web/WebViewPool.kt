package com.remoteeverything.app.web

import android.content.ComponentCallbacks2
import android.content.Context
import android.net.Uri
import android.view.ViewGroup
import android.webkit.WebView
import com.remoteeverything.app.ClientIdentity
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.RemoteApp
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 远程应用 WebView 常驻缓存池。
 *
 * 不预加载:首次进入才创建并加载页面(此时页面可见,SPA 全速启动);
 * 退出只卸载不销毁,再次进入原样恢复;渲染进程死亡、应用停止、连接切换、
 * 内存紧张时回收——进程死亡时缓存自然随之消失。
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
        val loaded: Boolean get() = progressFlow.value >= 100 && failedFlow.value == null
    }

    private val entries = LinkedHashMap<String, Entry>()
    private var config: ConnectionConfig? = null
    private var identity: ClientIdentity? = null

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

    /** 进入应用:命中缓存直接续上;失败条目重建;未命中立即创建加载。 */
    fun acquire(app: RemoteApp): Entry {
        val existing = entries[app.id]
        if (existing != null) {
            if (existing.failedFlow.value != null || existing.displayMode != displayModeResolver(app.id)) {
                invalidate(app.id)
            } else {
                existing.lastUsed = System.nanoTime()
                existing.webView.onResume()
                existing.webView.resumeTimers()
                existing.webView.invalidate()
                return existing
            }
        }
        val entry = createEntry(app)
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

    private fun pause(entry: Entry) {
        entry.lastUsed = System.nanoTime()
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
                entryRef?.takeIf { it.webView === view }?.progressFlow?.value = value
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
    }
}
