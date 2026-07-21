package com.remoteeverything.app

import android.content.Context
import android.content.pm.ActivityInfo
import androidx.core.content.edit
import com.remoteeverything.app.data.FloatingButton
import com.remoteeverything.app.data.FloatingLayout

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
            prefs.all.keys.filter { key -> key.startsWith("orientation_") || key.startsWith("display_") || key.startsWith("fk_") || key.startsWith("handle_") }.filter { marker in it }.forEach { key -> remove(key) }
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

    // 显示模式:phone(手机 UA)或 desktop(电脑 UA + 宽视口);应用级可取 global(跟随全局)
    fun globalDisplayMode(): String = prefs.getString("global_display_mode", "phone") ?: "phone"

    fun setGlobalDisplayMode(value: String) {
        prefs.edit { putString("global_display_mode", value) }
    }

    fun appDisplayMode(installationId: String, appId: String): String = prefs.getString(appKey("display", installationId, appId), "global") ?: "global"

    fun setAppDisplayMode(installationId: String, appId: String, value: String) {
        prefs.edit { putString(appKey("display", installationId, appId), value) }
    }

    fun resolveDisplayMode(installationId: String?, appId: String?): String {
        val appValue = if (installationId != null && appId != null) appDisplayMode(installationId, appId) else "global"
        val effective = if (appValue == "global") globalDisplayMode() else appValue
        return if (effective == "desktop") "desktop" else "phone"
    }

    // 悬浮按钮（独立按钮模型,按应用持久化）
    fun fkButtons(installationId: String, appId: String): List<FloatingButton> {
        val encoded = prefs.getString(appKey("fk_buttons", installationId, appId), null) ?: return emptyList()
        return FloatingLayout.decode(encoded)
    }

    fun setFkButtons(installationId: String, appId: String, buttons: List<FloatingButton>) {
        prefs.edit { putString(appKey("fk_buttons", installationId, appId), FloatingLayout.encode(buttons)) }
    }

    fun fkButtonsVisible(installationId: String, appId: String): Boolean =
        prefs.getBoolean(appKey("fk_buttons_visible", installationId, appId), true)

    fun setFkButtonsVisible(installationId: String, appId: String, visible: Boolean) {
        prefs.edit { putBoolean(appKey("fk_buttons_visible", installationId, appId), visible) }
    }

    // 边缘把手（按应用记忆纵坐标,归一化比例,-1 表示默认居中）
    fun handleY(installationId: String, appId: String): Float = prefs.getFloat(appKey("handle_y", installationId, appId), -1f)

    fun setHandleY(installationId: String, appId: String, y: Float) {
        prefs.edit { putFloat(appKey("handle_y", installationId, appId), y) }
    }
}
