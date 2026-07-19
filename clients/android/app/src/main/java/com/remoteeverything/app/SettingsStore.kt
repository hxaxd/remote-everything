package com.remoteeverything.app

import android.content.Context
import android.content.pm.ActivityInfo

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("remote_everything_settings", Context.MODE_PRIVATE)

    // 方向：global 设置取 system/portrait/landscape；应用级可取 global（跟随全局）
    fun globalOrientation(): String = prefs.getString("global_orientation", "system") ?: "system"

    fun setGlobalOrientation(value: String) {
        prefs.edit().putString("global_orientation", value).apply()
    }

    fun appOrientation(appId: String): String = prefs.getString("orientation_$appId", "global") ?: "global"

    fun setAppOrientation(appId: String, value: String) {
        prefs.edit().putString("orientation_$appId", value).apply()
    }

    fun resolveOrientation(appId: String?): Int {
        val appValue = if (appId != null) appOrientation(appId) else "global"
        val effective = if (appValue == "global") globalOrientation() else appValue
        return when (effective) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    // 悬浮快捷键（按应用记忆位置/缩放/可见性，坐标为父容器归一化比例）
    fun fkVisible(appId: String): Boolean = prefs.getBoolean("fk_visible_$appId", false)

    fun setFkVisible(appId: String, visible: Boolean) {
        prefs.edit().putBoolean("fk_visible_$appId", visible).apply()
    }

    fun fkX(appId: String): Float = prefs.getFloat("fk_x_$appId", -1f)
    fun fkY(appId: String): Float = prefs.getFloat("fk_y_$appId", -1f)

    fun setFkPosition(appId: String, x: Float, y: Float) {
        prefs.edit().putFloat("fk_x_$appId", x).putFloat("fk_y_$appId", y).apply()
    }

    fun fkScale(appId: String): Float = prefs.getFloat("fk_scale_$appId", 1f)

    fun setFkScale(appId: String, scale: Float) {
        prefs.edit().putFloat("fk_scale_$appId", scale).apply()
    }
}
