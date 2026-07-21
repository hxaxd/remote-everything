package com.remoteeverything.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class FloatingLayoutTest {

    private fun button(
        id: String = FloatingLayout.newId(),
        label: String = "Esc",
        action: String = FloatingButton.ACTION_KEY,
        key: String = "Escape",
        code: String = "Escape",
        ctrl: Boolean = false,
        text: String = "",
        x: Float = FloatingLayout.UNSET,
        y: Float = FloatingLayout.UNSET,
    ) = FloatingButton(id, label, action, key, code, ctrl, text = text, x = x, y = y)

    @Test
    fun `encode decode round trip preserves buttons`() {
        val buttons = listOf(
            button(x = 0.25f, y = 0.75f),
            button(label = "粘贴", action = FloatingButton.ACTION_PASTE, key = "", code = ""),
            button(label = "你好", action = FloatingButton.ACTION_TEXT, key = "", code = "", text = "你好,世界 🌏"),
            button(label = "Ctrl+A", key = "a", code = "KeyA", ctrl = true),
        )
        assertEquals(buttons, FloatingLayout.decode(FloatingLayout.encode(buttons)))
    }

    @Test
    fun `encode empty list round trips`() {
        assertEquals(emptyList<FloatingButton>(), FloatingLayout.decode(FloatingLayout.encode(emptyList())))
    }

    @Test
    fun `decode rejects wrong version`() {
        assertThrows { FloatingLayout.decode("""{"v":1,"buttons":[]}""") }
        assertThrows { FloatingLayout.decode("""{"v":3,"buttons":[]}""") }
    }

    @Test
    fun `decode rejects unknown field`() {
        assertThrows { FloatingLayout.decode("""{"v":2,"buttons":[],"extra":true}""") }
    }

    @Test
    fun `decode rejects malformed button id`() {
        assertThrows {
            FloatingLayout.decode("""{"v":2,"buttons":[{"id":"zz","label":"Esc","action":"key","key":"Escape","code":"Escape","ctrl":false,"alt":false,"shift":false,"text":"","x":-1,"y":-1}]}""")
        }
    }

    @Test
    fun `decode rejects duplicate ids`() {
        val id = FloatingLayout.newId()
        val one = """{"id":"$id","label":"Esc","action":"key","key":"Escape","code":"Escape","ctrl":false,"alt":false,"shift":false,"text":"","x":-1,"y":-1}"""
        assertThrows { FloatingLayout.decode("""{"v":2,"buttons":[$one,$one]}""") }
    }

    @Test
    fun `decode rejects too many buttons`() {
        val many = (1..FloatingLayout.MAX_BUTTONS + 1).joinToString(",") {
            """{"id":"${"%08d".format(it)}","label":"Esc","action":"key","key":"Escape","code":"Escape","ctrl":false,"alt":false,"shift":false,"text":"","x":-1,"y":-1}"""
                .replace("0", "a")
        }
        assertThrows { FloatingLayout.decode("""{"v":2,"buttons":[$many]}""") }
    }

    @Test
    fun `position outside range is rejected except unset sentinel`() {
        assertThrows { FloatingLayout.encode(listOf(button(x = -0.5f))) }
        assertThrows { FloatingLayout.encode(listOf(button(y = 1.01f))) }
        assertThrows { FloatingLayout.encode(listOf(button(x = Float.NaN))) }
        FloatingLayout.encode(listOf(button(x = FloatingLayout.UNSET, y = 0f)))
        FloatingLayout.encode(listOf(button(x = 1f, y = 1f)))
    }

    @Test
    fun `label constraints enforced`() {
        assertThrows { FloatingLayout.encode(listOf(button(label = ""))) }
        assertThrows { FloatingLayout.encode(listOf(button(label = "123456789"))) }
        assertThrows { FloatingLayout.encode(listOf(button(label = "a\nb"))) }
        FloatingLayout.encode(listOf(button(label = "Ctrl+A")))
    }

    @Test
    fun `key action requires key and code without text`() {
        assertThrows { FloatingLayout.encode(listOf(button(key = ""))) }
        assertThrows { FloatingLayout.encode(listOf(button(code = ""))) }
        assertThrows { FloatingLayout.encode(listOf(button(text = "x"))) }
    }

    @Test
    fun `paste action rejects payloads`() {
        val paste = button(action = FloatingButton.ACTION_PASTE, key = "", code = "")
        FloatingLayout.encode(listOf(paste))
        assertThrows { FloatingLayout.encode(listOf(paste.copy(text = "x"))) }
        assertThrows { FloatingLayout.encode(listOf(paste.copy(key = "v"))) }
    }

    @Test
    fun `text action requires text without key fields`() {
        assertThrows { FloatingLayout.encode(listOf(button(action = FloatingButton.ACTION_TEXT, key = "", code = ""))) }
        val textButton = button(action = FloatingButton.ACTION_TEXT, key = "", code = "", text = "命令 --help")
        val source = listOf(textButton)
        assertEquals(source, FloatingLayout.decode(FloatingLayout.encode(source)))
    }

    @Test
    fun `unknown action rejected`() {
        assertThrows { FloatingLayout.encode(listOf(button(action = "hack"))) }
    }

    @Test
    fun `new button appears at center with unique ids`() {
        val first = FloatingLayout.newButton()
        val second = FloatingLayout.newButton()
        assertEquals(0.5f, first.x, 0.001f)
        assertEquals(0.5f, first.y, 0.001f)
        assertEquals("Escape", first.key)
        assertNotEquals(first.id, second.id)
        FloatingLayout.encode(listOf(first, second))
    }

    private fun assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (expected: IllegalArgumentException) {
            return
        } catch (expected: org.json.JSONException) {
            return
        }
        throw AssertionError("expected IllegalArgumentException")
    }
}
