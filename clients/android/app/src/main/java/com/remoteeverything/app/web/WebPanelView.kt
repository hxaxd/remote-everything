package com.remoteeverything.app.web

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.remoteeverything.app.i18n.messageKey
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.store.WebAppPrefs
import com.remoteeverything.core.store.WebOrientation
import com.remoteeverything.core.store.WebUserAgent

/**
 * The panel one application's back gesture opens: how the screen is held, how
 * the page introduces itself, a refresh, and the way out. It replaces the bar
 * that used to sit over the page — the screen belongs to the page now, and
 * everything the bar carried (a reload and a close, and nothing else) is here,
 * as two settings rows and two actions.
 */
class WebPanelView(
    private val host: Context,
    private val palette: WebPalette,
    initial: WebAppPrefs,
    private val onOrientation: (WebOrientation) -> Unit,
    private val onUserAgent: (WebUserAgent) -> Unit,
    private val onRefresh: () -> Unit,
    private val onExit: () -> Unit,
) {

    private val density = host.resources.displayMetrics.density

    private var orientation = initial.orientation
    private var userAgent = initial.userAgent

    private val orientationControl: Segmented
    private val userAgentControl: Segmented

    val root: View

    init {
        orientationControl = Segmented(
            listOf(
                host.getString(messageKey(MessageKeys.WEB_ORIENTATION_SYSTEM)) to WebOrientation.SYSTEM,
                host.getString(messageKey(MessageKeys.WEB_ORIENTATION_PORTRAIT)) to WebOrientation.PORTRAIT,
                host.getString(messageKey(MessageKeys.WEB_ORIENTATION_LANDSCAPE)) to WebOrientation.LANDSCAPE,
            ),
        ) { chosen -> chooseOrientation(chosen as WebOrientation) }
        userAgentControl = Segmented(
            listOf(
                host.getString(messageKey(MessageKeys.WEB_USER_AGENT_MOBILE)) to WebUserAgent.MOBILE,
                host.getString(messageKey(MessageKeys.WEB_USER_AGENT_DESKTOP)) to WebUserAgent.DESKTOP,
            ),
        ) { chosen -> chooseUserAgent(chosen as WebUserAgent) }

        root = FrameLayout(host).apply {
            visibility = View.GONE
            addView(
                View(host).apply {
                    setBackgroundColor(palette.scrim)
                    isClickable = true
                    setOnClickListener { hide() }
                },
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
            )
            addView(
                buildCard(),
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.BOTTOM,
                ),
            )
        }

        orientationControl.select(orientation)
        userAgentControl.select(userAgent)
    }

    val visible: Boolean get() = root.visibility == View.VISIBLE

    fun show() {
        if (visible) return
        root.visibility = View.VISIBLE
        root.alpha = 0f
        root.animate().alpha(1f).setDuration(120).start()
    }

    fun hide() {
        if (!visible) return
        root.animate().alpha(0f).setDuration(120).withEndAction { root.visibility = View.GONE }.start()
    }

    private fun buildCard(): View = LinearLayout(host).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(18, palette.elevated).apply { setStroke(dp(1), palette.hairline) }
        setPadding(dp(16), dp(10), dp(16), dp(6))
        isClickable = true
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { setMargins(dp(10), dp(10), dp(10), dp(10)) }

        addView(settingRow(host.getString(messageKey(MessageKeys.WEB_ORIENTATION)), orientationControl.view))
        addView(settingRow(host.getString(messageKey(MessageKeys.WEB_USER_AGENT)), userAgentControl.view))
        addView(divider())
        addView(actionRow("⟳", host.getString(messageKey(MessageKeys.WEB_REFRESH))) { hide(); onRefresh() })
        addView(actionRow("✕", host.getString(messageKey(MessageKeys.WEB_EXIT))) { onExit() })
    }

    private fun settingRow(label: String, control: View): View = LinearLayout(host).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(6), 0, dp(6))
        addView(
            TextView(host).apply {
                text = label
                setTextColor(palette.secondary)
                textSize = 14f
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        addView(control)
    }

    private fun actionRow(glyph: String, label: String, onClick: () -> Unit): View = LinearLayout(host).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isClickable = true
        background = host.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { attrs ->
            val drawable = attrs.getDrawable(0)
            attrs.recycle()
            drawable
        }
        setPadding(dp(4), dp(12), dp(4), dp(12))
        addView(
            TextView(host).apply {
                text = glyph
                textSize = 17f
                setTextColor(palette.primary)
            },
            LinearLayout.LayoutParams(dp(30), ViewGroup.LayoutParams.WRAP_CONTENT),
        )
        addView(
            TextView(host).apply {
                text = label
                textSize = 16f
                setTextColor(palette.primary)
            },
        )
        setOnClickListener { onClick() }
    }

    private fun divider(): View = View(host).apply {
        setBackgroundColor(palette.hairline)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)).apply {
            setMargins(0, dp(6), 0, dp(2))
        }
    }

    private fun chooseOrientation(chosen: WebOrientation) {
        if (chosen == orientation) return
        orientation = chosen
        orientationControl.select(chosen)
        // The setting changes; the panel stays. Refresh and Exit are the two that
        // finish something — a choice here is a choice a person may want to follow
        // with another one, and a menu that closes under the hand is a menu that
        // has to be reopened.
        onOrientation(chosen)
    }

    private fun chooseUserAgent(chosen: WebUserAgent) {
        if (chosen == userAgent) return
        userAgent = chosen
        userAgentControl.select(chosen)
        onUserAgent(chosen)
    }

    /** A row of choices where exactly one is filled in — the accent says which. */
    private inner class Segmented(
        private val options: List<Pair<String, Any>>,
        private val onChosen: (Any) -> Unit,
    ) {
        val view: View = LinearLayout(host).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(10, palette.track)
            setPadding(dp(2), dp(2), dp(2), dp(2))
        }

        private val labels = mutableListOf<TextView>()

        init {
            for ((label, value) in options) {
                val entry = TextView(host).apply {
                    text = label
                    textSize = 13f
                    gravity = Gravity.CENTER
                    setPadding(dp(12), dp(6), dp(12), dp(6))
                    setOnClickListener { onChosen(value) }
                }
                labels += entry
                (view as LinearLayout).addView(entry)
            }
        }

        fun select(value: Any) {
            options.forEachIndexed { index, (_, option) ->
                val chosen = option == value
                labels[index].setTextColor(if (chosen) palette.accent else palette.secondary)
                labels[index].background = if (chosen) {
                    rounded(8, palette.at(palette.accent, 0.15f))
                } else null
            }
        }
    }

    private fun dp(value: Int): Int = (value * density).toInt()

    private fun rounded(radiusDp: Int, fill: Int): GradientDrawable = GradientDrawable().apply {
        cornerRadius = dp(radiusDp).toFloat()
        setColor(fill)
    }
}
