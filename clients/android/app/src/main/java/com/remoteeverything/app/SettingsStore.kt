package com.remoteeverything.app

import android.content.Context
import android.content.pm.ActivityInfo
import androidx.core.content.edit

class SettingsStore(context: Context) : SetupProfileStore {
    private val prefs = context.getSharedPreferences("remote_everything_settings", Context.MODE_PRIVATE)

    fun profiles(): List<ConnectionConfig> {
        val encoded = prefs.getString("profiles", "[]") ?: "[]"
        return ProfileCodec.decodeAll(encoded)
    }

    fun activeProfile(): ConnectionConfig? {
        val active = prefs.getString("active_profile", null) ?: return null
        return profiles().firstOrNull { it.installationId == active }
    }

    fun setActiveProfile(installationId: String) {
        require(profiles().any { it.installationId == installationId }) { "安装实例不存在" }
        prefs.commitChanges { putString("active_profile", installationId) }
    }

    override fun stageProfile(value: ConnectionConfig) {
        prefs.commitChanges { putString("staged_profile", ProfileCodec.encode(value).toString()) }
    }

    override fun stagedProfile(): ConnectionConfig? {
        val value = prefs.getString("staged_profile", null) ?: return null
        return ProfileCodec.decode(org.json.JSONObject(value))
    }

    override fun commitStagedProfile(): ConnectionConfig {
        val staged = requireNotNull(stagedProfile()) { "没有待激活安装实例" }
        val updated = profiles().filterNot { it.installationId == staged.installationId } + staged
        val encoded = ProfileCodec.encodeAll(updated)
        prefs.commitChanges {
            putString("profiles", encoded)
            putString("active_profile", staged.installationId)
        }
        return staged
    }

    override fun discardStagedProfile() {
        prefs.commitChanges { remove("staged_profile") }
    }

    fun removeProfile(installationId: String) {
        val updated = profiles().filterNot { it.installationId == installationId }
        val encoded = ProfileCodec.encodeAll(updated)
        prefs.commitChanges {
            putString("profiles", encoded)
            if (prefs.getString("active_profile", null) == installationId) remove("active_profile")
            if (stagedProfile()?.installationId == installationId) remove("staged_profile")
            val marker = "_${installationId}_"
            prefs.all.keys.filter { key -> key.startsWith("orientation_") || key.startsWith("fk_") }.filter { marker in it }.forEach { key -> remove(key) }
        }
    }

    // 方向：global 设置取 system/portrait/landscape；应用级可取 global（跟随全局）
    fun globalOrientation(): String = prefs.getString("global_orientation", "system") ?: "system"

    fun setGlobalOrientation(value: String) {
        prefs.edit { putString("global_orientation", value) }
    }

    private fun appKey(prefix: String, installationId: String, appId: String): String = "${prefix}_${installationId}_${appId}"

    fun appOrientation(installationId: String, appId: String): String = prefs.getString(appKey("orientation", installationId, appId), "global") ?: "global"

    fun setAppOrientation(installationId: String, appId: String, value: String) {
        prefs.edit { putString(appKey("orientation", installationId, appId), value) }
    }

    fun resolveOrientation(installationId: String?, appId: String?): Int {
        val appValue = if (installationId != null && appId != null) appOrientation(installationId, appId) else "global"
        val effective = if (appValue == "global") globalOrientation() else appValue
        return when (effective) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    // 悬浮快捷键（按应用记忆位置/缩放/可见性，坐标为父容器归一化比例）
    fun fkVisible(installationId: String, appId: String): Boolean = prefs.getBoolean(appKey("fk_visible", installationId, appId), false)

    fun setFkVisible(installationId: String, appId: String, visible: Boolean) {
        prefs.edit { putBoolean(appKey("fk_visible", installationId, appId), visible) }
    }

    fun fkX(installationId: String, appId: String): Float = prefs.getFloat(appKey("fk_x", installationId, appId), -1f)
    fun fkY(installationId: String, appId: String): Float = prefs.getFloat(appKey("fk_y", installationId, appId), -1f)

    fun setFkPosition(installationId: String, appId: String, x: Float, y: Float) {
        prefs.edit { putFloat(appKey("fk_x", installationId, appId), x); putFloat(appKey("fk_y", installationId, appId), y) }
    }

    fun fkScale(installationId: String, appId: String): Float = prefs.getFloat(appKey("fk_scale", installationId, appId), 1f)

    fun setFkScale(installationId: String, appId: String, scale: Float) {
        prefs.edit { putFloat(appKey("fk_scale", installationId, appId), scale) }
    }
}
