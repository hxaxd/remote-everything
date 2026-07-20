package com.remoteeverything.app

import android.content.Context
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

// 悬浮快捷键面板：⠿ 拖动移动、◢ 拖动缩放，按钮点击触发 onKey。
class FloatingKeysView(context: Context) : FrameLayout(context) {
    var onKey: ((action: String) -> Unit)? = null
    var onMoved: ((xFraction: Float, yFraction: Float) -> Unit)? = null
    var onResized: ((scale: Float) -> Unit)? = null

    private val pill: LinearLayout
    private val grip: TouchTextView
    private val resizeGrip: TouchTextView
    private var scaleFactor = 1f

    init {
        pill = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = Ui.rounded(this, 0xF20F172A.toInt(), 20f, Ui.cardBorder)
        }
        addView(pill, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        grip = TouchTextView(context).apply {
            text = "⠿"
            textSize = 15f
            setTextColor(Ui.textMuted)
            gravity = Gravity.CENTER
        }
        pill.addView(grip, LinearLayout.LayoutParams(dp(30), dp(36)))

        listOf("Esc" to "esc", "Tab" to "tab", "Ctrl+C" to "ctrlc", "粘贴" to "paste", "↵" to "enter").forEach { (label, action) ->
            pill.addView(keyButton(label) { onKey?.invoke(action) })
        }

        resizeGrip = TouchTextView(context).apply {
            text = "◢"
            textSize = 11f
            setTextColor(Ui.textMuted)
            setPadding(dp(8), dp(8), dp(4), dp(4))
        }
        addView(resizeGrip, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END))

        grip.setOnTouchListener(MoveTouchListener())
        resizeGrip.setOnTouchListener(ResizeTouchListener())
    }

    private fun keyButton(label: String, onClick: () -> Unit): TextView = TextView(context).apply {
        text = label
        textSize = 13f
        setTextColor(Ui.textSecondary)
        gravity = Gravity.CENTER
        background = Ui.rounded(this, Ui.accentSoft, 10f)
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36)).apply {
            marginStart = dp(4)
            minWidth = dp(42)
        }
    }

    fun setScaleFactor(scale: Float) {
        scaleFactor = scale
        pill.pivotX = 0f
        pill.pivotY = 0f
        pill.scaleX = scale
        pill.scaleY = scale
    }

    fun applyState(xFraction: Float, yFraction: Float, scale: Float) {
        setScaleFactor(scale)
        post {
            val parentView = parent as? ViewGroup ?: return@post
            val maxX = (parentView.width - width).coerceAtLeast(0)
            val maxY = (parentView.height - height).coerceAtLeast(0)
            if (xFraction >= 0f && yFraction >= 0f) {
                translationX = (maxX * xFraction).coerceIn(0f, maxX.toFloat())
                translationY = (maxY * yFraction).coerceIn(0f, maxY.toFloat())
            } else {
                translationX = maxX.toFloat()
                translationY = (maxY * 0.82f).coerceIn(0f, maxY.toFloat())
            }
        }
    }

    private inner class MoveTouchListener : OnTouchListener {
        private var startX = 0f
        private var startY = 0f
        private var startTX = 0f
        private var startTY = 0f

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            val parentView = parent as? ViewGroup ?: return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = event.rawX
                    startY = event.rawY
                    startTX = translationX
                    startTY = translationY
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    val maxX = (parentView.width - width).coerceAtLeast(0).toFloat()
                    val maxY = (parentView.height - height).coerceAtLeast(0).toFloat()
                    translationX = (startTX + event.rawX - startX).coerceIn(0f, maxX)
                    translationY = (startTY + event.rawY - startY).coerceIn(0f, maxY)
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    val maxX = (parentView.width - width).coerceAtLeast(1).toFloat()
                    val maxY = (parentView.height - height).coerceAtLeast(1).toFloat()
                    onMoved?.invoke(translationX / maxX, translationY / maxY)
                    view.performClick()
                    return true
                }
            }
            return false
        }
    }

    private inner class ResizeTouchListener : OnTouchListener {
        private var startX = 0f
        private var startScale = 1f

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = event.rawX
                    startScale = scaleFactor
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    val delta = (event.rawX - startX) / resources.displayMetrics.density / 220f
                    setScaleFactor((startScale + delta).coerceIn(0.7f, 1.6f))
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    onResized?.invoke(scaleFactor)
                    view.performClick()
                    return true
                }
            }
            return false
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private class TouchTextView(context: Context) : TextView(context) {
        override fun performClick(): Boolean = super.performClick()
    }
}
