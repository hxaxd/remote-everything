package com.remoteeverything.app

/** 连接按钮文案:输入为空时点击将从剪贴板读取。 */
fun connectionActionLabel(value: String): String = if (value.isBlank()) "粘贴并连接" else "连接"
