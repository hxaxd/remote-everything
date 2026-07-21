package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.remoteeverything.app.data.FloatingButton
import com.remoteeverything.app.data.FloatingLayout
import kotlin.math.roundToInt

/**
 * 悬浮按钮层:查看模式点击触发动作;编辑模式下按钮整体可拖动、点击打开编辑器。
 * 所有改动即时通过 [onCommit] 持久化。
 */
@Composable
fun FloatingButtonLayer(
    buttons: List<FloatingButton>,
    editMode: Boolean,
    onAction: (FloatingButton) -> Unit,
    onCommit: (List<FloatingButton>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var working by remember(buttons) { mutableStateOf(buttons) }
    val latestWorking by rememberUpdatedState(working)
    var editing by remember { mutableStateOf<FloatingButton?>(null) }
    val sizeMap = remember { mutableStateMapOf<String, IntSize>() }

    fun mutate(id: String, transform: (FloatingButton) -> FloatingButton): List<FloatingButton> {
        val next = latestWorking.map { if (it.id == id) transform(it) else it }
        working = next
        return next
    }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val containerWidth = constraints.maxWidth
        val containerHeight = constraints.maxHeight
        val gridPx = with(LocalDensity.current) { 8.dp.toPx() }
        val cascadeStepPx = with(LocalDensity.current) { 56.dp.toPx() }

        working.forEachIndexed { index, button ->
            key(button.id) {
                val size = sizeMap[button.id] ?: IntSize.Zero
                val maxX = (containerWidth - size.width).coerceAtLeast(1)
                val maxY = (containerHeight - size.height).coerceAtLeast(1)
                // 未手动摆放的按钮从右下角向上依次排列
                val px = if (button.x < 0) maxX.toFloat() else (button.x * maxX).coerceIn(0f, maxX.toFloat())
                val py = if (button.y < 0) {
                    (maxY * 0.82f - index * cascadeStepPx).coerceIn(0f, maxY.toFloat())
                } else {
                    (button.y * maxY).coerceIn(0f, maxY.toFloat())
                }

                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = if (editMode) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.92f),
                    modifier = Modifier
                        .offset { IntOffset(px.roundToInt(), py.roundToInt()) }
                        .onSizeChanged { sizeMap[button.id] = it }
                        .then(
                            if (editMode) {
                                Modifier.drawBehind {
                                    drawRoundRect(
                                        color = Color(0xFF60A5FA),
                                        cornerRadius = CornerRadius(16.dp.toPx()),
                                        style = Stroke(
                                            width = 1.dp.toPx(),
                                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(14f, 10f)),
                                        ),
                                    )
                                }
                            } else {
                                Modifier
                            },
                        )
                        .pointerInput(button.id, editMode, containerWidth, containerHeight) {
                            if (!editMode) return@pointerInput
                            var origin = Offset.Zero
                            var accumulated = Offset.Zero
                            detectDragGestures(
                                onDragStart = {
                                    val current = latestWorking.firstOrNull { it.id == button.id } ?: return@detectDragGestures
                                    val currentSize = sizeMap[button.id] ?: IntSize.Zero
                                    val mX = (containerWidth - currentSize.width).coerceAtLeast(1)
                                    val mY = (containerHeight - currentSize.height).coerceAtLeast(1)
                                    origin = Offset(
                                        if (current.x < 0) mX.toFloat() else current.x * mX,
                                        if (current.y < 0) mY * 0.82f else current.y * mY,
                                    )
                                    accumulated = Offset.Zero
                                },
                                onDrag = { change, drag ->
                                    change.consume()
                                    accumulated += drag
                                    val currentSize = sizeMap[button.id] ?: IntSize.Zero
                                    val mX = (containerWidth - currentSize.width).coerceAtLeast(1)
                                    val mY = (containerHeight - currentSize.height).coerceAtLeast(1)
                                    val nx = ((origin.x + accumulated.x).coerceIn(0f, mX.toFloat()) / gridPx).roundToInt() * gridPx
                                    val ny = ((origin.y + accumulated.y).coerceIn(0f, mY.toFloat()) / gridPx).roundToInt() * gridPx
                                    mutate(button.id) { it.copy(x = nx / mX, y = ny / mY) }
                                },
                                onDragEnd = { onCommit(working) },
                            )
                        }
                        .clickable {
                            if (editMode) editing = button else onAction(button)
                        },
                ) {
                    Text(
                        button.label,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }
            }
        }
    }

    editing?.let { target ->
        ButtonEditorDialog(
            initial = target,
            onDismiss = { editing = null },
            onDelete = {
                val next = latestWorking.filterNot { it.id == target.id }
                working = next
                onCommit(next)
                editing = null
            },
            onSave = { updated ->
                val next = mutate(target.id) { updated }
                onCommit(next)
                editing = null
            },
        )
    }
}

private data class KeyPreset(val label: String, val key: String, val code: String, val ctrl: Boolean = false)

private val keyPresets = listOf(
    KeyPreset("Esc", "Escape", "Escape"),
    KeyPreset("Tab", "Tab", "Tab"),
    KeyPreset("↵", "Enter", "Enter"),
    KeyPreset("Ctrl+C", "c", "KeyC", ctrl = true),
    KeyPreset("Ctrl+V", "v", "KeyV", ctrl = true),
    KeyPreset("Ctrl+X", "x", "KeyX", ctrl = true),
    KeyPreset("Ctrl+Z", "z", "KeyZ", ctrl = true),
    KeyPreset("Ctrl+A", "a", "KeyA", ctrl = true),
    KeyPreset("↑", "ArrowUp", "ArrowUp"),
    KeyPreset("↓", "ArrowDown", "ArrowDown"),
    KeyPreset("←", "ArrowLeft", "ArrowLeft"),
    KeyPreset("→", "ArrowRight", "ArrowRight"),
    KeyPreset("Home", "Home", "Home"),
    KeyPreset("End", "End", "End"),
)

/** 按钮编辑器:修改名称、类型(按键/剪贴板/文本)与参数,或删除按钮。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun ButtonEditorDialog(
    initial: FloatingButton,
    onDismiss: () -> Unit,
    onSave: (FloatingButton) -> Unit,
    onDelete: () -> Unit,
) {
    var label by remember { mutableStateOf(initial.label) }
    var action by remember { mutableStateOf(initial.action) }
    var keyName by remember { mutableStateOf(initial.key.ifEmpty { "Escape" }) }
    var keyCode by remember { mutableStateOf(initial.code.ifEmpty { "Escape" }) }
    var ctrl by remember { mutableStateOf(initial.ctrl) }
    var alt by remember { mutableStateOf(initial.alt) }
    var shift by remember { mutableStateOf(initial.shift) }
    var text by remember { mutableStateOf(initial.text) }
    var error by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("编辑按钮") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (action == FloatingButton.ACTION_KEY) {
                    Text("常用", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    FlowRow(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp)) {
                        keyPresets.forEach { preset ->
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                                modifier = Modifier.clickable {
                                    label = preset.label
                                    keyName = preset.key
                                    keyCode = preset.code
                                    ctrl = preset.ctrl
                                    alt = false
                                    shift = false
                                },
                            ) {
                                Text(
                                    preset.label,
                                    style = MaterialTheme.typography.labelMedium,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                                )
                            }
                        }
                    }
                }
                OutlinedTextField(
                    value = label,
                    onValueChange = { label = it; error = "" },
                    label = { Text("名称(最多 8 字)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                )
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    listOf(
                        FloatingButton.ACTION_KEY to "按键",
                        FloatingButton.ACTION_PASTE to "剪贴板",
                        FloatingButton.ACTION_TEXT to "文本",
                    ).forEachIndexed { index, (value, labelText) ->
                        SegmentedButton(
                            selected = action == value,
                            onClick = { action = value; error = "" },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                        ) { Text(labelText) }
                    }
                }
                when (action) {
                    FloatingButton.ACTION_KEY -> {
                        OutlinedTextField(
                            value = keyName,
                            onValueChange = { keyName = it; error = "" },
                            label = { Text("key(如 Escape、c、ArrowUp)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                        )
                        OutlinedTextField(
                            value = keyCode,
                            onValueChange = { keyCode = it; error = "" },
                            label = { Text("code(如 Escape、KeyC)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            listOf("Ctrl" to ctrl, "Alt" to alt, "Shift" to shift).forEachIndexed { index, (name, checked) ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Checkbox(
                                        checked = checked,
                                        onCheckedChange = {
                                            when (index) {
                                                0 -> ctrl = it
                                                1 -> alt = it
                                                else -> shift = it
                                            }
                                        },
                                    )
                                    Text(name, style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }
                    FloatingButton.ACTION_TEXT -> {
                        OutlinedTextField(
                            value = text,
                            onValueChange = { text = it; error = "" },
                            label = { Text("要插入的文本") },
                            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                        )
                    }
                    else -> {
                        Text(
                            "点击后将系统剪贴板内容插入到网页焦点输入框。",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    }
                }
                if (error.isNotEmpty()) {
                    Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val candidate = initial.copy(
                    label = label.trim(),
                    action = action,
                    key = if (action == FloatingButton.ACTION_KEY) keyName.trim() else "",
                    code = if (action == FloatingButton.ACTION_KEY) keyCode.trim() else "",
                    ctrl = ctrl, alt = alt, shift = shift,
                    text = if (action == FloatingButton.ACTION_TEXT) text else "",
                )
                val valid = runCatching { FloatingLayout.encode(listOf(candidate)) }.isSuccess
                if (!valid) {
                    error = "内容无效:检查名称、键值或文本"
                    return@TextButton
                }
                onSave(candidate)
            }) { Text("保存") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDelete) { Text("删除", color = MaterialTheme.colorScheme.error) }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        },
    )
}
