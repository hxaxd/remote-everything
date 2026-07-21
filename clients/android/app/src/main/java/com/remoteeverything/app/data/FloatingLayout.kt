package com.remoteeverything.app.data

import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/**
 * 悬浮按钮的持久化模型。
 *
 * 每个按钮独立记录位置与动作;位置为父容器归一化比例,-1 表示未手动摆放
 * (渲染时从右下角依次排列)。编解码遵循项目严格风格:字段集合精确匹配。
 */
data class FloatingButton(
    val id: String,
    val label: String,
    val action: String,
    val key: String = "",
    val code: String = "",
    val ctrl: Boolean = false,
    val alt: Boolean = false,
    val shift: Boolean = false,
    val text: String = "",
    val x: Float = FloatingLayout.UNSET,
    val y: Float = FloatingLayout.UNSET,
) {
    companion object {
        const val ACTION_KEY = "key"
        const val ACTION_PASTE = "paste"
        const val ACTION_TEXT = "text"
    }
}

object FloatingLayout {
    const val UNSET = -1f
    const val MAX_BUTTONS = 16

    private val idPattern = Regex("^[a-f0-9]{8}$")
    private val random = SecureRandom()

    private val buttonFields = setOf("id", "label", "action", "key", "code", "ctrl", "alt", "shift", "text", "x", "y")
    private val rootFields = setOf("v", "buttons")

    fun newId(): String {
        val bytes = ByteArray(4).also(random::nextBytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /** 新建按钮:默认 Esc 键,出现在屏幕正中间。 */
    fun newButton(): FloatingButton =
        FloatingButton(newId(), "Esc", FloatingButton.ACTION_KEY, key = "Escape", code = "Escape", x = 0.5f, y = 0.5f)

    fun encode(buttons: List<FloatingButton>): String {
        require(buttons.size <= MAX_BUTTONS) { "悬浮按钮数量超限" }
        buttons.forEach(::validateButton)
        val array = JSONArray()
        buttons.forEach { button ->
            array.put(
                JSONObject()
                    .put("id", button.id)
                    .put("label", button.label)
                    .put("action", button.action)
                    .put("key", button.key)
                    .put("code", button.code)
                    .put("ctrl", button.ctrl)
                    .put("alt", button.alt)
                    .put("shift", button.shift)
                    .put("text", button.text)
                    .put("x", button.x.toDouble())
                    .put("y", button.y.toDouble()),
            )
        }
        return JSONObject().put("v", 2).put("buttons", array).toString()
    }

    fun decode(value: String): List<FloatingButton> {
        val root = JSONObject(value)
        require(root.keys().asSequence().toSet() == rootFields) { "悬浮按钮字段无效" }
        require(root.getInt("v") == 2) { "悬浮按钮版本不受支持" }
        val array = root.getJSONArray("buttons")
        require(array.length() <= MAX_BUTTONS) { "悬浮按钮数量超限" }
        val ids = mutableSetOf<String>()
        return buildList {
            for (index in 0 until array.length()) {
                val value = array.getJSONObject(index)
                require(value.keys().asSequence().toSet() == buttonFields) { "悬浮按钮字段无效" }
                val button = FloatingButton(
                    id = value.getString("id"),
                    label = value.getString("label"),
                    action = value.getString("action"),
                    key = value.getString("key"),
                    code = value.getString("code"),
                    ctrl = value.getBoolean("ctrl"),
                    alt = value.getBoolean("alt"),
                    shift = value.getBoolean("shift"),
                    text = value.getString("text"),
                    x = value.getDouble("x").toFloat(),
                    y = value.getDouble("y").toFloat(),
                )
                validateButton(button)
                require(ids.add(button.id)) { "悬浮按钮 ID 重复" }
                add(button)
            }
        }
    }

    private fun validateButton(button: FloatingButton) {
        require(idPattern.matches(button.id)) { "悬浮按钮 ID 无效" }
        require(validLabel(button.label)) { "悬浮按钮名称无效" }
        require(button.x.isFinite() && button.y.isFinite()) { "悬浮按钮数值无效" }
        require(validFraction(button.x) && validFraction(button.y)) { "悬浮按钮位置无效" }
        when (button.action) {
            FloatingButton.ACTION_KEY -> {
                require(validPayload(button.key, 32) && validPayload(button.code, 32)) { "悬浮按钮键值无效" }
                require(button.text.isEmpty()) { "悬浮按钮内容无效" }
            }
            FloatingButton.ACTION_PASTE -> {
                require(button.key.isEmpty() && button.code.isEmpty() && button.text.isEmpty()) { "悬浮按钮内容无效" }
            }
            FloatingButton.ACTION_TEXT -> {
                require(button.key.isEmpty() && button.code.isEmpty()) { "悬浮按钮键值无效" }
                require(validPayload(button.text, 512)) { "悬浮按钮文本无效" }
            }
            else -> throw IllegalArgumentException("悬浮按钮动作无效")
        }
    }

    private fun validFraction(value: Float): Boolean = value == UNSET || value in 0f..1f

    private fun validLabel(value: String): Boolean =
        value.isNotEmpty() && value.codePointCount(0, value.length) <= 8 && value.none { it.code < 32 || it.code == 127 }

    private fun validPayload(value: String, maximum: Int): Boolean =
        value.isNotEmpty() && value.codePointCount(0, value.length) <= maximum && value.none { it.code < 32 || it.code == 127 }
}
