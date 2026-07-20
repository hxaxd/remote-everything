package com.remoteeverything.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FloatingLayoutTest {

    private fun key(
        id: String = FloatingLayout.newId(),
        label: String = "Esc",
        action: String = FloatingKey.ACTION_KEY,
        key: String = "Escape",
        code: String = "Escape",
        ctrl: Boolean = false,
        text: String = "",
    ) = FloatingKey(id, label, action, key, code, ctrl, text = text)

    private fun panel(
        id: String = FloatingLayout.newId(),
        x: Float = FloatingLayout.UNSET,
        y: Float = FloatingLayout.UNSET,
        scale: Float = 1f,
        keys: List<FloatingKey> = listOf(key()),
    ) = FloatingPanel(id, x, y, scale, keys)

    @Test
    fun `encode decode round trip preserves panels`() {
        val panels = listOf(
            panel(
                x = 0.25f, y = 0.75f, scale = 1.2f,
                keys = listOf(
                    key(label = "Ctrl+C", key = "c", code = "KeyC", ctrl = true),
                    key(label = "粘贴", action = FloatingKey.ACTION_PASTE, key = "", code = ""),
                    key(label = "你好", action = FloatingKey.ACTION_TEXT, key = "", code = "", text = "你好，世界 🌏"),
                ),
            ),
            panel(keys = listOf(key(label = "↑", key = "ArrowUp", code = "ArrowUp"))),
        )
        assertEquals(panels, FloatingLayout.decode(FloatingLayout.encode(panels)))
    }

    @Test
    fun `encode empty list round trips`() {
        assertEquals(emptyList<FloatingPanel>(), FloatingLayout.decode(FloatingLayout.encode(emptyList())))
    }

    @Test
    fun `decode rejects wrong version`() {
        assertThrows { FloatingLayout.decode("""{"v":2,"panels":[]}""") }
    }

    @Test
    fun `decode rejects unknown field`() {
        assertThrows { FloatingLayout.decode("""{"v":1,"panels":[],"extra":true}""") }
    }

    @Test
    fun `decode rejects malformed panel id`() {
        assertThrows {
            FloatingLayout.decode("""{"v":1,"panels":[{"id":"zz","x":-1,"y":-1,"scale":1,"keys":[]}]}""")
        }
    }

    @Test
    fun `decode rejects duplicate panel ids`() {
        val id = FloatingLayout.newId()
        val json = """{"v":1,"panels":[${panelJson(id)},${panelJson(id)}]}"""
        assertThrows { FloatingLayout.decode(json) }
    }

    @Test
    fun `decode rejects too many panels`() {
        val panels = (1..FloatingLayout.MAX_PANELS + 1).joinToString(",") { panelJson(FloatingLayout.newId()) }
        assertThrows { FloatingLayout.decode("""{"v":1,"panels":[$panels]}""") }
    }

    @Test
    fun `scale outside range is rejected`() {
        assertThrows { FloatingLayout.encode(listOf(panel(scale = FloatingLayout.MIN_SCALE - 0.01f))) }
        assertThrows { FloatingLayout.encode(listOf(panel(scale = FloatingLayout.MAX_SCALE + 0.01f))) }
        assertThrows { FloatingLayout.encode(listOf(panel(scale = Float.NaN))) }
    }

    @Test
    fun `position outside range is rejected except unset sentinel`() {
        assertThrows { FloatingLayout.encode(listOf(panel(x = -0.5f))) }
        assertThrows { FloatingLayout.encode(listOf(panel(y = 1.01f))) }
        assertThrows { FloatingLayout.encode(listOf(panel(x = Float.POSITIVE_INFINITY))) }
        // -1 哨兵与边界值合法
        FloatingLayout.encode(listOf(panel(x = FloatingLayout.UNSET, y = 0f)))
        FloatingLayout.encode(listOf(panel(x = 1f, y = 1f)))
    }

    @Test
    fun `label constraints enforced`() {
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(label = ""))))) }
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(label = "123456789"))))) }
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(label = "a\nb"))))) }
        FloatingLayout.encode(listOf(panel(keys = listOf(key(label = "Ctrl+A")))))
    }

    @Test
    fun `key action requires key and code without text`() {
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(key = ""))))) }
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(code = ""))))) }
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(text = "x"))))) }
    }

    @Test
    fun `paste action rejects payloads`() {
        val paste = key(action = FloatingKey.ACTION_PASTE, key = "", code = "")
        FloatingLayout.encode(listOf(panel(keys = listOf(paste))))
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(paste.copy(text = "x"))))) }
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(paste.copy(key = "v"))))) }
    }

    @Test
    fun `text action requires text without key fields`() {
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(action = FloatingKey.ACTION_TEXT, key = "", code = ""))))) }
        val textKey = key(action = FloatingKey.ACTION_TEXT, key = "", code = "", text = "命令 --help")
        val source = listOf(panel(keys = listOf(textKey)))
        assertEquals(source, FloatingLayout.decode(FloatingLayout.encode(source)))
    }

    @Test
    fun `unknown action rejected`() {
        assertThrows { FloatingLayout.encode(listOf(panel(keys = listOf(key(action = "hack"))))) }
    }

    @Test
    fun `migrate legacy returns null when nothing customized`() {
        assertNull(FloatingLayout.migrateLegacy(visible = false, x = FloatingLayout.UNSET, y = FloatingLayout.UNSET, scale = 1f))
    }

    @Test
    fun `migrate legacy keeps customized position and clamps scale`() {
        val panels = FloatingLayout.migrateLegacy(visible = true, x = 0.3f, y = 0.6f, scale = 2.5f)!!
        assertEquals(1, panels.size)
        assertEquals(0.3f, panels[0].x, 0.0001f)
        assertEquals(0.6f, panels[0].y, 0.0001f)
        assertEquals(FloatingLayout.MAX_SCALE, panels[0].scale, 0.0001f)
        assertEquals(5, panels[0].keys.size)
    }

    @Test
    fun `migrate legacy preserves position even when hidden`() {
        val panels = FloatingLayout.migrateLegacy(visible = false, x = 0.1f, y = 0.2f, scale = 1f)!!
        assertEquals(1, panels.size)
    }

    @Test
    fun `default keys match legacy five actions`() {
        val keys = FloatingLayout.defaultKeys()
        assertEquals(5, keys.size)
        assertEquals("Escape", keys[0].key)
        assertEquals("Tab", keys[1].key)
        assertEquals("c", keys[2].key)
        assertTrue(keys[2].ctrl)
        assertEquals(FloatingKey.ACTION_PASTE, keys[3].action)
        assertEquals("Enter", keys[4].key)
        // 每次生成的 id 唯一
        assertNotEquals(keys[0].id, keys[1].id)
    }

    private fun panelJson(id: String): String =
        """{"id":"$id","x":-1,"y":-1,"scale":1,"keys":[{"id":"${FloatingLayout.newId()}","label":"Esc","action":"key","key":"Escape","code":"Escape","ctrl":false,"alt":false,"shift":false,"text":""}]}"""

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
