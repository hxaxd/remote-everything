package com.remoteeverything.app

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView

data class ConnectingView(val root: View, val status: TextView, val retry: Button)
data class CatalogView(val root: View, val body: LinearLayout)

object ScreenRenderer {
	private fun dp(context: Context, value: Int): Int = (value * context.resources.displayMetrics.density + 0.5f).toInt()

    fun contentRoot(context: Context): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Ui.bg)
    }

    fun fullScroll(context: Context, content: View): ScrollView = ScrollView(context).apply {
        isFillViewport = true
        setBackgroundColor(Ui.bg)
        addView(content)
    }

    fun header(context: Context, title: String, subtitle: String?, action: (() -> View)?): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titles = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        titles.addView(Ui.label(context, title, 28f, Ui.textPrimary, Typeface.BOLD))
        if (subtitle != null) {
            titles.addView(Ui.label(context, subtitle, 13f, Ui.textSecondary).apply { setPadding(0, Ui.dp(this, 4), 0, 0) })
        }
        row.addView(titles, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        action?.let { row.addView(it()) }
        return row
    }

    fun sectionLabel(context: Context, text: String): View = Ui.label(context, text, 13f, Ui.textSecondary, Typeface.BOLD).apply {
        setPadding(0, 0, 0, Ui.dp(this, 8))
    }

    fun optionRow(context: Context, options: List<Pair<String, String>>, current: String, onSelect: (String) -> Unit): View {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = Ui.rounded(this, Ui.card, 16f, Ui.cardBorder)
            val padding = Ui.dp(this, 4)
            setPadding(padding, padding, padding, padding)
        }
        options.forEach { (value, label) ->
            val selected = value == current
            val item = TextView(context).apply {
                text = label
                textSize = 13f
                gravity = Gravity.CENTER
                setTextColor(if (selected) Color.WHITE else Ui.textSecondary)
                if (selected) background = Ui.rounded(this, Ui.accent, 12f)
                setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 10))
                setOnClickListener { onSelect(value) }
            }
            row.addView(item, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        return row
    }

    fun messageCard(context: Context, title: String, detail: String): View = Ui.card(context).apply {
        val padding = Ui.dp(this, 20)
        setPadding(padding, padding, padding, padding)
        addView(Ui.label(context, title, 17f, Ui.textPrimary, Typeface.BOLD))
        addView(Ui.label(context, detail, 13f, Ui.textSecondary).apply { setPadding(0, Ui.dp(this, 8), 0, 0) })
    }

    fun statusText(code: String) = when (code) {
        "ready" -> "● 正在运行"
        "starting" -> "● 正在启动"
        "stopping" -> "● 正在停止"
        "stopped" -> "● 已停止"
        "computer_offline" -> "● 电脑离线"
        else -> "● 状态不可用"
    }

    fun statusColor(code: String) = when (code) {
        "ready" -> Ui.ok
        "starting", "stopping", "stopped" -> Ui.warn
        "computer_offline" -> Ui.textSecondary
        else -> Ui.danger
    }

    fun connectionSetup(
        context: Context,
        profiles: List<ConnectionConfig>,
        staged: ConnectionConfig?,
        canOpen: (ConnectionConfig) -> Boolean,
        onScan: () -> Unit,
        onPaste: (String, TextView, Button) -> Unit,
        onResume: (ConnectionConfig, TextView, Button) -> Unit,
        onOpen: (ConnectionConfig, TextView) -> Unit,
        onDelete: (ConnectionConfig) -> Unit,
    ): View {
        val root = contentRoot(context).apply { setPadding(dp(context, 24), dp(context, 48), dp(context, 24), dp(context, 32)) }
        root.addView(Ui.label(context, "远程万物", 30f, Ui.textPrimary, Typeface.BOLD))
        root.addView(Ui.label(context, "扫描 Agent 展示的初始化二维码", 15f, Ui.textSecondary).apply { setPadding(0, dp(context, 8), 0, dp(context, 24)) })
        val status = Ui.label(context, "", 13f, Ui.danger).apply { setPadding(0, dp(context, 14), 0, dp(context, 8)) }
        root.addView(Ui.primaryButton(context, "扫描连接").apply { setOnClickListener { onScan() } }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 50)))
        val setupLink = EditText(context).apply {
            hint = "或粘贴一条初始化链接"
            textSize = 14f
            setTextColor(Ui.textPrimary)
            setHintTextColor(Ui.textMuted)
            setPadding(dp(context, 14), 0, dp(context, 14), 0)
            background = Ui.rounded(this, Ui.card, 14f, Ui.cardBorder)
            isSingleLine = true
        }
        root.addView(setupLink, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 52)).apply { topMargin = dp(context, 16) })
        root.addView(Ui.ghostButton(context, "粘贴并连接").apply {
            setOnClickListener { onPaste(setupLink.text.toString(), status, this) }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 48)).apply { topMargin = dp(context, 8) })
        staged?.let { profile ->
            root.addView(Ui.ghostButton(context, "继续激活 ${profile.name}").apply {
                setOnClickListener { onResume(profile, status, this) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 48)).apply { topMargin = dp(context, 8) })
        }
        if (profiles.isNotEmpty()) {
            root.addView(sectionLabel(context, "已有连接").apply { setPadding(0, dp(context, 24), 0, dp(context, 8)) })
            profiles.forEach { profile ->
                val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
                row.addView(Ui.ghostButton(context, profile.name).apply {
                    setOnClickListener {
                        if (canOpen(profile)) onOpen(profile, status) else status.text = "该连接缺少设备身份，请重新扫描初始化二维码"
                    }
                }, LinearLayout.LayoutParams(0, dp(context, 46), 1f).apply { rightMargin = dp(context, 6) })
                row.addView(Ui.ghostButton(context, "删除").apply { setOnClickListener { onDelete(profile) } },
                    LinearLayout.LayoutParams(dp(context, 76), dp(context, 46)).apply { leftMargin = dp(context, 6) })
                root.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 46)).apply { topMargin = dp(context, 6) })
            }
        }
        root.addView(status, Ui.matchWrap())
        return fullScroll(context, root)
    }

    fun connecting(context: Context, onRetry: (TextView, Button) -> Unit): ConnectingView {
        val status = Ui.label(context, "正在验证初始化信息…", 13f, Ui.textSecondary)
        val root = contentRoot(context).apply { setPadding(dp(context, 24), dp(context, 64), dp(context, 24), dp(context, 32)) }
        root.addView(Ui.label(context, "正在连接", 28f, Ui.textPrimary, Typeface.BOLD))
        root.addView(status, Ui.matchWrap())
        val retry = Ui.ghostButton(context, "重试连接").apply { setOnClickListener { onRetry(status, this) } }
        root.addView(retry,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 48)).apply { topMargin = dp(context, 16) })
        return ConnectingView(root, status, retry)
    }

    fun catalog(context: Context, onSettings: () -> Unit): CatalogView {
        val content = contentRoot(context).apply { setPadding(dp(context, 20), dp(context, 48), dp(context, 20), dp(context, 32)) }
        content.addView(header(context, "远程万物", "我的应用") {
            TextView(context).apply {
                text = "⚙"
                textSize = 22f
                setTextColor(Ui.textSecondary)
                setPadding(dp(context, 10), dp(context, 4), dp(context, 4), dp(context, 4))
                setOnClickListener { onSettings() }
            }
        })
        val body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(context, 24), 0, 0) }
        body.addView(ProgressBar(context).apply { isIndeterminate = true }, LinearLayout.LayoutParams(dp(context, 32), dp(context, 32)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        content.addView(body, Ui.matchWrap())
        return CatalogView(fullScroll(context, content), body)
    }

    fun settings(
        context: Context,
        store: SettingsStore,
        configured: ConnectionConfig?,
        onBack: () -> Unit,
        onOrientation: (String) -> Unit,
        onConnections: () -> Unit,
    ): View {
        val content = contentRoot(context).apply { setPadding(dp(context, 20), dp(context, 48), dp(context, 20), dp(context, 32)) }
        content.addView(header(context, "设置", "全局选项，应用级设置优先于全局") {
            TextView(context).apply {
                text = "‹"; textSize = 26f; setTextColor(Ui.textSecondary)
                setPadding(dp(context, 8), 0, dp(context, 10), 0); setOnClickListener { onBack() }
            }
        })
        val body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(context, 22), 0, 0) }
        body.addView(sectionLabel(context, "屏幕方向（全局）"))
        body.addView(optionRow(context, listOf("system" to "跟随系统", "portrait" to "竖屏锁定", "landscape" to "横屏锁定"), store.globalOrientation(), onOrientation))
        body.addView(Ui.label(context, "单个应用的方向可在远程界面的边缘菜单里单独设置，应用级设置优先于此全局项。", 12f, Ui.textMuted).apply { setPadding(0, dp(context, 16), 0, 0) })
        body.addView(sectionLabel(context, "连接").apply { setPadding(0, dp(context, 28), 0, dp(context, 8)) })
        body.addView(Ui.label(context, configured?.let { "${it.name} · ${if (it.mode == "lan") "局域网" else "公网"} · ${it.gatewayOrigin}" } ?: "未配置", 13f, Ui.textSecondary).apply { setPadding(0, 0, 0, dp(context, 12)) })
        body.addView(Ui.ghostButton(context, "管理连接").apply { setOnClickListener { onConnections() } }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 48)))
        content.addView(body, Ui.matchWrap())
        return fullScroll(context, content)
    }

    fun applicationCard(context: Context, app: RemoteApp, canEnter: Boolean, onPower: (View) -> Unit, onEnter: () -> Unit): View {
        val card = Ui.card(context).apply { setPadding(dp(context, 16), dp(context, 16), dp(context, 16), dp(context, 16)) }
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val accent = runCatching { Color.parseColor(app.accent) }.getOrDefault(Ui.accent)
        row.addView(Ui.label(context, app.icon.take(4), 20f, Color.WHITE, Typeface.BOLD).apply { gravity = Gravity.CENTER; background = Ui.rounded(this, accent, 14f) }, LinearLayout.LayoutParams(dp(context, 48), dp(context, 48)))
        val names = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(context, 13), 0, 0, 0) }
        names.addView(Ui.label(context, app.name, 17f, Ui.textPrimary, Typeface.BOLD))
        names.addView(Ui.label(context, statusText(app.code), 12f, statusColor(app.code)).apply { setPadding(0, dp(context, 3), 0, 0) })
        row.addView(names, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        card.addView(row, Ui.matchWrap())
        if (app.description.isNotBlank()) card.addView(Ui.label(context, app.description, 13f, Ui.textSecondary).apply { setPadding(0, dp(context, 13), 0, dp(context, 13)) }, Ui.matchWrap())
        val actions = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        val power = Ui.ghostButton(context, if (app.code == "stopped") "启动" else "停止").apply {
            isEnabled = app.code == "ready" || app.code == "stopped"
            setOnClickListener { isEnabled = false; onPower(this) }
        }
        val enter = Ui.primaryButton(context, "进入").apply { isEnabled = canEnter; setOnClickListener { onEnter() } }
        actions.addView(power, LinearLayout.LayoutParams(0, dp(context, 46), 1f).apply { rightMargin = dp(context, 7) })
        actions.addView(enter, LinearLayout.LayoutParams(0, dp(context, 46), 1f).apply { leftMargin = dp(context, 7) })
        card.addView(actions, Ui.matchWrap())
        return card.apply { layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(context, 12) } }
    }

    fun remoteFailure(context: Context, app: RemoteApp, detail: String, onRetry: () -> Unit, onBack: () -> Unit): View {
        val root = contentRoot(context).apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(context, 28), dp(context, 72), dp(context, 28), dp(context, 32)) }
        root.addView(Ui.label(context, app.name, 26f, Ui.textPrimary, Typeface.BOLD))
        root.addView(Ui.label(context, "远程页面没有成功打开", 17f, Ui.danger, Typeface.BOLD).apply { gravity = Gravity.CENTER; setPadding(0, dp(context, 26), 0, dp(context, 10)) })
        root.addView(Ui.label(context, detail, 13f, Ui.textSecondary).apply { gravity = Gravity.CENTER; setPadding(0, 0, 0, dp(context, 24)) })
        root.addView(Ui.primaryButton(context, "重试").apply { setOnClickListener { onRetry() } }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 50)).apply { bottomMargin = dp(context, 10) })
        root.addView(Ui.ghostButton(context, "返回目录").apply { setOnClickListener { onBack() } }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(context, 50)))
        return fullScroll(context, root)
    }
}
