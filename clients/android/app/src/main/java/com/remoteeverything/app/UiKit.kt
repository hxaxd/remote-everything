package com.remoteeverything.app

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

object Ui {
    val bg = Color.rgb(2, 6, 23)
    val card = Color.rgb(15, 23, 42)
    val cardBorder = Color.rgb(30, 41, 59)
    val textPrimary = Color.WHITE
    val textSecondary = Color.rgb(148, 163, 184)
    val textMuted = Color.rgb(100, 116, 139)
    val accent = Color.rgb(37, 99, 235)
    val accentSoft = Color.rgb(30, 58, 95)
    val accentText = Color.rgb(96, 165, 250)
    val danger = Color.rgb(248, 113, 113)
    val ok = Color.rgb(134, 239, 172)
    val warn = Color.rgb(253, 186, 116)

    fun dp(view: View, value: Int): Int = (value * view.resources.displayMetrics.density + 0.5f).toInt()

    fun label(context: Context, text: String, size: Float, color: Int, style: Int = Typeface.NORMAL): TextView =
        TextView(context).apply {
            this.text = text
            textSize = size
            setTextColor(color)
            setTypeface(typeface, style)
        }

    fun rounded(color: Int, radiusDp: Float, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(color)
        cornerRadius = radiusDp
        if (stroke != null) setStroke(2, stroke)
    }

    fun card(context: Context): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(card, 22f, cardBorder)
    }

    fun primaryButton(context: Context, text: String): Button = Button(context).apply {
        this.text = text
        setTextColor(Color.WHITE)
        textSize = 15f
        isAllCaps = false
        background = rounded(accent, 14f)
    }

    fun ghostButton(context: Context, text: String): Button = Button(context).apply {
        this.text = text
        setTextColor(textSecondary)
        textSize = 15f
        isAllCaps = false
        background = rounded(card, 14f, cardBorder)
    }

    fun matchWrap() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

    fun matchParent() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
}
