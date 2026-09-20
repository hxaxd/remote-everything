package com.remoteeverything.app.web

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.remoteeverything.app.R

/**
 * Builds error view overlays when web loading fails or credentials are lost.
 */
object WebErrorView {

    fun create(
        context: Context,
        message: String,
        dark: Boolean,
        onRetry: () -> Unit,
        onClose: () -> Unit,
    ): View {
        val density = context.resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val primary = if (dark) Color.parseColor("#E8E8E8") else Color.parseColor("#1A1A1A")

        val layout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }

        val textView = TextView(context).apply {
            text = message
            setTextColor(primary)
            textSize = 16f
            gravity = Gravity.CENTER
        }
        layout.addView(textView)

        val buttons = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(24), 0, 0)
        }

        val closeBtn = Button(context).apply {
            text = context.getString(R.string.action_back)
            setOnClickListener { onClose() }
        }
        val retryBtn = Button(context).apply {
            text = context.getString(R.string.action_retry)
            setOnClickListener { onRetry() }
        }
        buttons.addView(closeBtn)
        val spacer = View(context).apply { layoutParams = ViewGroup.LayoutParams(dp(16), 1) }
        buttons.addView(spacer)
        buttons.addView(retryBtn)
        layout.addView(buttons)

        return layout
    }
}
