package com.remoteeverything.app.web

import android.webkit.WebView
import com.remoteeverything.app.data.FloatingKey
import org.json.JSONObject

/**
 * 悬浮按键动作 → WebView JS 注入。
 * 键事件逻辑与旧版 MainActivity.keyJs/pasteJs 一致,扩展了 alt/shift 修饰键与自定义文本。
 */
class ShortcutInjector(
    private val webView: () -> WebView?,
    private val clipboardText: () -> String?,
) {
    fun inject(key: FloatingKey) {
        val js = when (key.action) {
            FloatingKey.ACTION_KEY -> keyJs(key.key, key.code, key.ctrl, key.alt, key.shift)
            FloatingKey.ACTION_PASTE -> clipboardText()?.let(::insertJs)
            FloatingKey.ACTION_TEXT -> insertJs(key.text)
            else -> null
        } ?: return
        webView()?.evaluateJavascript(js, null)
    }

    private fun keyJs(key: String, code: String, ctrl: Boolean, alt: Boolean, shift: Boolean): String = """
        (function(){
          const el = document.activeElement || document.body;
          ['keydown','keyup'].forEach(t => el.dispatchEvent(new KeyboardEvent(t, {key: ${JSONObject.quote(key)}, code: ${JSONObject.quote(code)}, ctrlKey: $ctrl, altKey: $alt, shiftKey: $shift, bubbles: true, cancelable: true})));
        })();
    """.trimIndent()

    private fun insertJs(text: String): String {
        val encoded = JSONObject.quote(text)
        return """
        (function(){
          const t = $encoded;
          const el = document.activeElement;
          if (!el) return;
          if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
            const s = el.selectionStart || 0, e = el.selectionEnd || s;
            el.value = el.value.slice(0, s) + t + el.value.slice(e);
            el.selectionStart = el.selectionEnd = s + t.length;
            el.dispatchEvent(new Event('input', {bubbles: true}));
          } else if (el.isContentEditable) {
            document.execCommand('insertText', false, t);
          }
        })();
        """.trimIndent()
    }
}
