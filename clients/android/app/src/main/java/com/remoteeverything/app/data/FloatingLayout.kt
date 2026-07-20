package com.remoteeverything.app.data

import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/**
 * 悬浮快捷键面板的持久化模型。
 *
 * - 一个应用可以有多个面板,每个面板有自己的位置/缩放和一组按键;
 * - 位置为父容器归一化比例,-1 表示未手动摆放(渲染时取默认位置:右下角);
 * - 编解码遵循项目既有的严格风格:字段集合必须精确匹配,非法内容直接拒绝。
 */
data class FloatingKey(
    val id: String,
    val label: String,
    val action: String,
    val key: String = "",
    val code: String = "",
    val ctrl: Boolean = false,
    val alt: Boolean = false,
    val shift: Boolean = false,
    val text: String = "",
) {
    companion object {
        const val ACTION_KEY = "key"
        const val ACTION_PASTE = "paste"
        const val ACTION_TEXT = "text"
    }
}

data class FloatingPanel(
    val id: String,
    val x: Float,
    val y: Float,
    val scale: Float,
    val keys: List<FloatingKey>,
)

object FloatingLayout {
    const val MIN_SCALE = 0.7f
    const val MAX_SCALE = 1.6f
    const val MAX_PANELS = 8
    const val MAX_KEYS_PER_PANEL = 12
    const val UNSET = -1f

    private val idPattern = Regex("^[a-f0-9]{8}$")
    private val random = SecureRandom()

    private val keyFields = setOf("id", "label", "action", "key", "code", "ctrl", "alt", "shift", "text")
    private val panelFields = setOf("id", "x", "y", "scale", "keys")
    private val rootFields = setOf("v", "panels")

    fun newId(): String {
        val bytes = ByteArray(4).also(random::nextBytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    fun defaultKeys(): List<FloatingKey> = listOf(
        FloatingKey(newId(), "Esc", FloatingKey.ACTION_KEY, key = "Escape", code = "Escape"),
        FloatingKey(newId(), "Tab", FloatingKey.ACTION_KEY, key = "Tab", code = "Tab"),
        FloatingKey(newId(), "Ctrl+C", FloatingKey.ACTION_KEY, key = "c", code = "KeyC", ctrl = true),
        FloatingKey(newId(), "粘贴", FloatingKey.ACTION_PASTE),
        FloatingKey(newId(), "↵", FloatingKey.ACTION_KEY, key = "Enter", code = "Enter"),
    )

    fun defaultPanel(): FloatingPanel = FloatingPanel(newId(), UNSET, UNSET, 1f, defaultKeys())

    /** 旧版单面板配置迁移:没有任何旧自定义(未显示过也未摆放过)时返回 null。 */
    fun migrateLegacy(visible: Boolean, x: Float, y: Float, scale: Float): List<FloatingPanel>? {
        if (!visible && x == UNSET && y == UNSET) return null
        val clampedScale = scale.coerceIn(MIN_SCALE, MAX_SCALE)
        return listOf(FloatingPanel(newId(), x, y, clampedScale, defaultKeys()))
    }

    fun encode(panels: List<FloatingPanel>): String {
        require(panels.size <= MAX_PANELS) { "悬浮面板数量超限" }
        val array = JSONArray()
        panels.forEach { panel -> array.put(encodePanel(panel)) }
        return JSONObject().put("v", 1).put("panels", array).toString()
    }

    private fun encodePanel(panel: FloatingPanel): JSONObject {
        validatePanel(panel)
        val keys = JSONArray()
        panel.keys.forEach { key ->
            keys.put(
                JSONObject()
                    .put("id", key.id)
                    .put("label", key.label)
                    .put("action", key.action)
                    .put("key", key.key)
                    .put("code", key.code)
                    .put("ctrl", key.ctrl)
                    .put("alt", key.alt)
                    .put("shift", key.shift)
                    .put("text", key.text),
            )
        }
        return JSONObject()
            .put("id", panel.id)
            .put("x", panel.x.toDouble())
            .put("y", panel.y.toDouble())
            .put("scale", panel.scale.toDouble())
            .put("keys", keys)
    }

    fun decode(value: String): List<FloatingPanel> {
        val root = JSONObject(value)
        require(root.keys().asSequence().toSet() == rootFields) { "悬浮面板字段无效" }
        require(root.getInt("v") == 1) { "悬浮面板版本不受支持" }
        val array = root.getJSONArray("panels")
        require(array.length() <= MAX_PANELS) { "悬浮面板数量超限" }
        val ids = mutableSetOf<String>()
        return buildList {
            for (index in 0 until array.length()) {
                val panel = decodePanel(array.getJSONObject(index))
                require(ids.add(panel.id)) { "悬浮面板 ID 重复" }
                add(panel)
            }
        }
    }

    private fun decodePanel(value: JSONObject): FloatingPanel {
        require(value.keys().asSequence().toSet() == panelFields) { "悬浮面板字段无效" }
        val rawKeys = value.getJSONArray("keys")
        require(rawKeys.length() <= MAX_KEYS_PER_PANEL) { "悬浮按键数量超限" }
        val ids = mutableSetOf<String>()
        val keys = buildList {
            for (index in 0 until rawKeys.length()) {
                val key = decodeKey(rawKeys.getJSONObject(index))
                require(ids.add(key.id)) { "悬浮按键 ID 重复" }
                add(key)
            }
        }
        val panel = FloatingPanel(
            id = value.getString("id"),
            x = value.getDouble("x").toFloat(),
            y = value.getDouble("y").toFloat(),
            scale = value.getDouble("scale").toFloat(),
            keys = keys,
        )
        validatePanel(panel)
        return panel
    }

    private fun decodeKey(value: JSONObject): FloatingKey {
        require(value.keys().asSequence().toSet() == keyFields) { "悬浮按键字段无效" }
        return FloatingKey(
            id = value.getString("id"),
            label = value.getString("label"),
            action = value.getString("action"),
            key = value.getString("key"),
            code = value.getString("code"),
            ctrl = value.getBoolean("ctrl"),
            alt = value.getBoolean("alt"),
            shift = value.getBoolean("shift"),
            text = value.getString("text"),
        )
    }

    private fun validatePanel(panel: FloatingPanel) {
        require(idPattern.matches(panel.id)) { "悬浮面板 ID 无效" }
        require(panel.keys.size <= MAX_KEYS_PER_PANEL) { "悬浮按键数量超限" }
        require(panel.x.isFinite() && panel.y.isFinite() && panel.scale.isFinite()) { "悬浮面板数值无效" }
        require(validFraction(panel.x) && validFraction(panel.y)) { "悬浮面板位置无效" }
        require(panel.scale in MIN_SCALE..MAX_SCALE) { "悬浮面板缩放无效" }
        panel.keys.forEach(::validateKey)
    }

    private fun validateKey(key: FloatingKey) {
        require(idPattern.matches(key.id)) { "悬浮按键 ID 无效" }
        require(validLabel(key.label)) { "悬浮按键名称无效" }
        when (key.action) {
            FloatingKey.ACTION_KEY -> {
                require(validPayload(key.key, 32) && validPayload(key.code, 32)) { "悬浮按键键值无效" }
                require(key.text.isEmpty()) { "悬浮按键内容无效" }
            }
            FloatingKey.ACTION_PASTE -> {
                require(key.key.isEmpty() && key.code.isEmpty() && key.text.isEmpty()) { "悬浮按键内容无效" }
            }
            FloatingKey.ACTION_TEXT -> {
                require(key.key.isEmpty() && key.code.isEmpty()) { "悬浮按键键值无效" }
                require(validPayload(key.text, 512)) { "悬浮按键文本无效" }
            }
            else -> throw IllegalArgumentException("悬浮按键动作无效")
        }
    }

    private fun validFraction(value: Float): Boolean = value == UNSET || value in 0f..1f

    private fun validLabel(value: String): Boolean =
        value.isNotEmpty() && value.codePointCount(0, value.length) <= 8 && value.none { it.code < 32 || it.code == 127 }

    private fun validPayload(value: String, maximum: Int): Boolean =
        value.isNotEmpty() && value.codePointCount(0, value.length) <= maximum && value.none { it.code < 32 || it.code == 127 }
}
