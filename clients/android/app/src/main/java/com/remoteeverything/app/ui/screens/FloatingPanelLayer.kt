package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.remoteeverything.app.data.FloatingKey
import com.remoteeverything.app.data.FloatingLayout
import com.remoteeverything.app.data.FloatingPanel
import kotlin.math.roundToInt

/**
 * 悬浮面板层:查看模式下点击按键触发动作;编辑模式下可拖动、缩放、
 * 增删按键、增删面板,所有改动即时通过 [onCommit] 持久化。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FloatingPanelLayer(
    panels: List<FloatingPanel>,
    editMode: Boolean,
    onKey: (FloatingKey) -> Unit,
    onCommit: (List<FloatingPanel>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var working by remember(panels) { mutableStateOf(panels) }
    val latestWorking by rememberUpdatedState(working)
    var keyEditor by remember { mutableStateOf<KeyEditorTarget?>(null) }
    val sizeMap = remember { mutableStateMapOf<String, IntSize>() }

    fun mutate(id: String, transform: (FloatingPanel) -> FloatingPanel): List<FloatingPanel> {
        val next = latestWorking.map { if (it.id == id) transform(it) else it }
        working = next
        return next
    }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val containerWidth = constraints.maxWidth
        val containerHeight = constraints.maxHeight
        val density = LocalDensity.current
        val gridPx = with(density) { 8.dp.toPx() }

        working.forEach { panel ->
            key(panel.id) {
                val panelSize = sizeMap[panel.id] ?: IntSize.Zero
                val maxX = (containerWidth - panelSize.width).coerceAtLeast(1)
                val maxY = (containerHeight - panelSize.height).coerceAtLeast(1)
                val px = if (panel.x < 0) maxX.toFloat() else (panel.x * maxX).coerceIn(0f, maxX.toFloat())
                val py = if (panel.y < 0) maxY * 0.82f else (panel.y * maxY).coerceIn(0f, maxY.toFloat())

                Column(
                    modifier = Modifier
                        .offset { IntOffset(px.roundToInt(), py.roundToInt()) }
                        .graphicsLayer {
                            scaleX = panel.scale
                            scaleY = panel.scale
                            transformOrigin = TransformOrigin(0f, 0f)
                        }
                        .onSizeChanged { sizeMap[panel.id] = it }
                        .then(
                            if (editMode) {
                                Modifier.drawBehind {
                                    drawRoundRect(
                                        color = Color(0xFF60A5FA),
                                        cornerRadius = CornerRadius(20.dp.toPx()),
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
                        .background(Color(0xF20F172A), androidx.compose.foundation.shape.RoundedCornerShape(20.dp))
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                ) {
                    FlowRow(
                        modifier = Modifier.widthIn(max = 300.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalArrangement = Arrangement.Center,
                    ) {
                        if (editMode) {
                            Icon(
                                Icons.Filled.DragHandle,
                                contentDescription = "拖动",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(30.dp)
                                    .pointerInput(panel.id, containerWidth, containerHeight) {
                                        var origin = Offset.Zero
                                        var accumulated = Offset.Zero
                                        detectDragGestures(
                                            onDragStart = {
                                                val size = sizeMap[panel.id] ?: IntSize.Zero
                                                val mX = (containerWidth - size.width).coerceAtLeast(1)
                                                val mY = (containerHeight - size.height).coerceAtLeast(1)
                                                val current = latestWorking.firstOrNull { it.id == panel.id } ?: return@detectDragGestures
                                                origin = Offset(
                                                    if (current.x < 0) mX.toFloat() else current.x * mX,
                                                    if (current.y < 0) mY * 0.82f else current.y * mY,
                                                )
                                                accumulated = Offset.Zero
                                            },
                                            onDrag = { change, drag ->
                                                change.consume()
                                                accumulated += drag
                                                val size = sizeMap[panel.id] ?: IntSize.Zero
                                                val mX = (containerWidth - size.width).coerceAtLeast(1)
                                                val mY = (containerHeight - size.height).coerceAtLeast(1)
                                                val nx = ((origin.x + accumulated.x).coerceIn(0f, mX.toFloat()) / gridPx).roundToInt() * gridPx
                                                val ny = ((origin.y + accumulated.y).coerceIn(0f, mY.toFloat()) / gridPx).roundToInt() * gridPx
                                                mutate(panel.id) { it.copy(x = nx / mX, y = ny / mY) }
                                            },
                                            onDragEnd = { onCommit(working) },
                                        )
                                    },
                            )
                        }
                        panel.keys.forEach { key ->
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = if (editMode) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.secondaryContainer,
                                modifier = Modifier.clickable {
                                    if (editMode) keyEditor = KeyEditorTarget(panel.id, key) else onKey(key)
                                },
                            ) {
                                Text(
                                    key.label,
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                                )
                            }
                        }
                        if (editMode) {
                            Icon(
                                Icons.Filled.Add,
                                contentDescription = "添加按键",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .size(30.dp)
                                    .clickable { keyEditor = KeyEditorTarget(panel.id, null) },
                            )
                        }
                    }
                    if (editMode) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription = "删除面板",
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier
                                    .size(26.dp)
                                    .clickable {
                                        val next = latestWorking.filterNot { it.id == panel.id }
                                        working = next
                                        onCommit(next)
                                    },
                            )
                            Icon(
                                Icons.Filled.OpenInFull,
                                contentDescription = "缩放",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(26.dp)
                                    .pointerInput(panel.id) {
                                        var startScale = 1f
                                        var accX = 0f
                                        detectDragGestures(
                                            onDragStart = {
                                                startScale = latestWorking.firstOrNull { it.id == panel.id }?.scale ?: 1f
                                                accX = 0f
                                            },
                                            onDrag = { change, drag ->
                                                change.consume()
                                                accX += drag.x
                                                val next = (startScale + accX / density.density / 220f)
                                                    .coerceIn(FloatingLayout.MIN_SCALE, FloatingLayout.MAX_SCALE)
                                                mutate(panel.id) { it.copy(scale = (next * 100).roundToInt() / 100f) }
                                            },
                                            onDragEnd = { onCommit(working) },
                                        )
                                    },
                            )
                        }
                    }
                }
            }
        }
    }

    keyEditor?.let { target ->
        KeyEditorDialog(
            initial = target.key,
            onDismiss = { keyEditor = null },
            onDelete = if (target.key != null) {
                {
                    val next = mutate(target.panelId) { panel -> panel.copy(keys = panel.keys.filterNot { it.id == target.key.id }) }
                    onCommit(next)
                    keyEditor = null
                }
            } else {
                null
            },
            onSave = { key ->
                val next = mutate(target.panelId) { panel ->
                    val exists = panel.keys.any { it.id == key.id }
                    panel.copy(
                        keys = if (exists) panel.keys.map { if (it.id == key.id) key else it }
                        else panel.keys + key,
                    )
                }
                onCommit(next)
                keyEditor = null
            },
        )
    }
}

private class KeyEditorTarget(val panelId: String, val key: FloatingKey?)

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

/** 按键编辑器:新建或编辑一个悬浮按键。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun KeyEditorDialog(
    initial: FloatingKey?,
    onDismiss: () -> Unit,
    onSave: (FloatingKey) -> Unit,
    onDelete: (() -> Unit)?,
) {
    var label by remember { mutableStateOf(initial?.label ?: "") }
    var action by remember { mutableStateOf(initial?.action ?: FloatingKey.ACTION_KEY) }
    var keyName by remember { mutableStateOf(initial?.key ?: "Escape") }
    var keyCode by remember { mutableStateOf(initial?.code ?: "Escape") }
    var ctrl by remember { mutableStateOf(initial?.ctrl ?: false) }
    var alt by remember { mutableStateOf(initial?.alt ?: false) }
    var shift by remember { mutableStateOf(initial?.shift ?: false) }
    var text by remember { mutableStateOf(initial?.text ?: "") }
    var error by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (initial == null) "添加按键" else "编辑按键") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (action == FloatingKey.ACTION_KEY) {
                    Text("常用", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
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
                        FloatingKey.ACTION_KEY to "按键",
                        FloatingKey.ACTION_PASTE to "剪贴板",
                        FloatingKey.ACTION_TEXT to "文本",
                    ).forEachIndexed { index, (value, labelText) ->
                        SegmentedButton(
                            selected = action == value,
                            onClick = { action = value; error = "" },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                        ) { Text(labelText) }
                    }
                }
                when (action) {
                    FloatingKey.ACTION_KEY -> {
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
                    FloatingKey.ACTION_TEXT -> {
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
                val candidate = FloatingKey(
                    id = initial?.id ?: FloatingLayout.newId(),
                    label = label.trim(),
                    action = action,
                    key = if (action == FloatingKey.ACTION_KEY) keyName.trim() else "",
                    code = if (action == FloatingKey.ACTION_KEY) keyCode.trim() else "",
                    ctrl = ctrl, alt = alt, shift = shift,
                    text = if (action == FloatingKey.ACTION_TEXT) text else "",
                )
                val valid = runCatching {
                    FloatingLayout.encode(listOf(FloatingPanel(FloatingLayout.newId(), FloatingLayout.UNSET, FloatingLayout.UNSET, 1f, listOf(candidate))))
                }.isSuccess
                if (!valid) {
                    error = "内容无效:检查名称、键值或文本"
                    return@TextButton
                }
                onSave(candidate)
            }) { Text("保存") }
        },
        dismissButton = {
            Row {
                if (onDelete != null) {
                    TextButton(onClick = onDelete) { Text("删除", color = MaterialTheme.colorScheme.error) }
                }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        },
    )
}
