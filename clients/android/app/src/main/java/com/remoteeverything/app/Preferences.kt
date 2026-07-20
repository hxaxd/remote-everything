package com.remoteeverything.app

import android.content.SharedPreferences

@Suppress("UseKtx")
fun SharedPreferences.commitChanges(block: SharedPreferences.Editor.() -> Unit) {
    val editor = edit()
    editor.block()
    check(editor.commit())
}
