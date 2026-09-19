package com.remoteeverything.app.web

import android.graphics.Color

/**
 * The colours the web host draws with. The host is a plain view tree, not a
 * Compose screen, so it carries the same tokens by hand — the values are the
 * ones the theme uses, kept here in one place for the host's pieces.
 */
class WebPalette(dark: Boolean) {
    val background: Int = if (dark) Color.parseColor("#141414") else Color.parseColor("#FAFAFA")
    val elevated: Int = if (dark) Color.parseColor("#1E1E1E") else Color.WHITE
    val primary: Int = if (dark) Color.parseColor("#E8E8E8") else Color.parseColor("#1A1A1A")
    val secondary: Int = if (dark) Color.parseColor("#A0A0A0") else Color.parseColor("#6B6B6B")
    val accent: Int = if (dark) Color.parseColor("#6E97C4") else Color.parseColor("#3B6EA5")
    val hairline: Int = if (dark) Color.parseColor("#2E2E2E") else Color.parseColor("#E5E5E5")
    val track: Int = if (dark) Color.parseColor("#2A2A2A") else Color.parseColor("#EFEFEF")
    val scrim: Int = Color.parseColor("#66000000")

    /** The colour at a fraction of its strength: fills say things quietly. */
    fun at(color: Int, alpha: Float): Int =
        Color.argb((255 * alpha).toInt(), Color.red(color), Color.green(color), Color.blue(color))
}
