package com.remoteeverything.app.ui.screens

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Rect
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.data.FloatingButton
import com.remoteeverything.app.data.FloatingLayout
import com.remoteeverything.app.ui.CatalogUiState
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.components.CenteredLoading
import com.remoteeverything.app.web.ShortcutInjector
import com.remoteeverything.app.web.WebViewPool
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * 远程应用界面:预热 WebView + 边缘把手 + 底部控制面板 + 悬浮面板层。
 * 返回手势分级:先关面板,再退出编辑,最后才回目录(WebView 保留在池中)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteScreen(
    appId: String,
    session: SessionViewModel,
    pool: WebViewPool,
    onImmersive: (Boolean) -> Unit,
    onOrientation: (Int) -> Unit,
    onExitToCatalog: () -> Unit,
) {
    val profile by session.activeProfile.collectAsStateWithLifecycle()
    val catalog by session.catalog.collectAsStateWithLifecycle()
    val app = (catalog as? CatalogUiState.Ready)?.snapshot?.apps?.firstOrNull { it.id == appId }
    val installationId = profile?.installationId
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var sheetOpen by remember { mutableStateOf(false) }
    var editMode by remember { mutableStateOf(false) }
    var reloadTick by remember { mutableIntStateOf(0) }

    var buttons by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.fkButtons(it, appId) } ?: emptyList())
    }
    var buttonsVisible by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.fkButtonsVisible(it, appId) } ?: true)
    }
    var appOrientation by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.appOrientation(it, appId) } ?: "global")
    }
    var appDisplayMode by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.appDisplayMode(it, appId) } ?: "global")
    }
    var handleY by remember(installationId, appId) {
        mutableFloatStateOf(installationId?.let { session.settings.handleY(it, appId) } ?: -1f)
    }

    DisposableEffect(Unit) {
        onImmersive(true)
        onDispose { onImmersive(false) }
    }

    LaunchedEffect(installationId, appId) {
        onOrientation(session.settings.resolveOrientation(installationId, appId))
    }

    // 目录刷新后应用消失(被移除)→ 自动返回
    LaunchedEffect(catalog) {
        val ready = catalog as? CatalogUiState.Ready ?: return@LaunchedEffect
        if (ready.snapshot.apps.isNotEmpty() && ready.snapshot.apps.none { it.id == appId }) onExitToCatalog()
    }

    if (app == null || installationId == null) {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            CenteredLoading(Modifier.align(Alignment.Center))
        }
        return
    }

    val entry = remember(appId, reloadTick) { pool.acquire(app) }
    val progress by entry.progress.collectAsStateWithLifecycle()
    val pageFailed by entry.failed.collectAsStateWithLifecycle()

    DisposableEffect(entry) {
        onDispose { pool.release(entry) }
    }

    // 渲染进程死亡 → 自动重建并重新加载
    DisposableEffect(appId) {
        val previous = pool.onEntryGone
        pool.onEntryGone = { goneId ->
            if (goneId == appId) reloadTick += 1
            previous?.invoke(goneId)
        }
        onDispose { pool.onEntryGone = previous }
    }

    val injector = remember(appId) {
        ShortcutInjector(
            webView = { pool.entry(appId)?.webView },
            clipboardText = {
                val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                manager.primaryClip
                    ?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)
                    ?.coerceToText(context)
                    ?.toString()
            },
        )
    }

    fun persistButtons(next: List<FloatingButton>) {
        buttons = next
        session.settings.setFkButtons(installationId, appId, next)
    }

    fun reload() {
        pool.release(appId)
        pool.invalidate(appId)
        reloadTick += 1
    }

    fun closeSheet() {
        scope.launch { sheetState.hide() }.invokeOnCompletion { sheetOpen = false }
    }

    BackHandler(enabled = !sheetOpen && !editMode) { onExitToCatalog() }
    BackHandler(enabled = !sheetOpen && editMode) { editMode = false }
    BackHandler(enabled = sheetOpen) { closeSheet() }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color(0xFF020617)),
    ) {
        val containerHeight = constraints.maxHeight

        key(reloadTick) {
            AndroidView(
                factory = {
                    entry.webView.apply { post { applyGestureExclusion(this) } }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }

        // 加载失败:展示真实错误与重试入口
        pageFailed?.let { detail ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(androidx.compose.ui.graphics.Color(0xFF020617))
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    Icons.Filled.ErrorOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text("远程页面没有成功打开", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(8.dp))
                Text(
                    detail,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                Button(onClick = { reload() }, modifier = Modifier.fillMaxWidth()) { Text("重试") }
                Spacer(Modifier.height(10.dp))
                OutlinedButton(onClick = { onExitToCatalog() }, modifier = Modifier.fillMaxWidth()) { Text("返回目录") }
            }
        }

        if (progress < 100 && pageFailed == null) {
            LinearProgressIndicator(
                progress = { progress / 100f },
                modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter),
            )
        }

        // 左右边缘滑动 → 打开控制面板(取代直接返回;返回键仍可用)
        EdgeSwipeZone(alignment = Alignment.CenterStart, direction = 1f, onTrigger = { sheetOpen = true })
        EdgeSwipeZone(alignment = Alignment.CenterEnd, direction = -1f, onTrigger = { sheetOpen = true })

        if (buttonsVisible && buttons.isNotEmpty() && pageFailed == null) {
            FloatingButtonLayer(
                buttons = buttons,
                editMode = editMode,
                onAction = { injector.inject(it) },
                onCommit = ::persistButtons,
            )
        }

        if (editMode) {
            Surface(
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 20.dp)
                    .clickable { editMode = false },
            ) {
                Text(
                    "编辑悬浮按钮 · 点这里完成",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
        }

        // 边缘把手:点按打开控制面板,上下拖动调整位置(按应用记忆);热区宽于视觉条
        run {
            val handleHeightPx = with(androidx.compose.ui.platform.LocalDensity.current) { 72.dp.toPx() }
            val maxCenter = (containerHeight - handleHeightPx).coerceAtLeast(1f)
            val centerPx = (if (handleY < 0f) 0.5f else handleY).coerceIn(0f, 1f) * maxCenter
            Box(
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .offset { IntOffset(0, (centerPx - handleHeightPx / 2f).roundToInt()) }
                    .width(28.dp)
                    .height(72.dp)
                    .pointerInput(appId) {
                        detectTapGestures {
                            sheetOpen = true
                        }
                    }
                    .pointerInput(appId, containerHeight) {
                        var startCenter = 0f
                        var accY = 0f
                        detectDragGestures(
                            onDragStart = {
                                startCenter = (if (handleY < 0f) 0.5f else handleY).coerceIn(0f, 1f) * maxCenter
                                accY = 0f
                            },
                            onDrag = { change, drag ->
                                change.consume()
                                accY += drag.y
                                handleY = ((startCenter + accY) / maxCenter).coerceIn(0.05f, 0.95f)
                            },
                            onDragEnd = {
                                session.settings.setHandleY(installationId, appId, handleY)
                            },
                        )
                    },
            ) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .width(12.dp)
                        .height(72.dp)
                        .clip(RoundedCornerShape(topStart = 8.dp, bottomStart = 8.dp))
                        .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.55f)),
                )
            }
        }
    }

    if (sheetOpen) {
        ModalBottomSheet(
            onDismissRequest = { sheetOpen = false },
            sheetState = sheetState,
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 36.dp),
            ) {
                Text(app.name, style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(20.dp))

                SectionLabel("屏幕方向")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf("global" to "跟随全局", "system" to "跟随系统", "portrait" to "竖屏", "landscape" to "横屏")
                        .forEachIndexed { index, (value, label) ->
                            SegmentedButton(
                                selected = appOrientation == value,
                                onClick = {
                                    appOrientation = value
                                    session.settings.setAppOrientation(installationId, appId, value)
                                    onOrientation(session.settings.resolveOrientation(installationId, appId))
                                },
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = 4),
                            ) { Text(label, style = MaterialTheme.typography.labelMedium) }
                        }
                }
                Spacer(Modifier.height(22.dp))

                SectionLabel("显示模式")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf("global" to "跟随全局", "phone" to "手机", "desktop" to "电脑")
                        .forEachIndexed { index, (value, label) ->
                            SegmentedButton(
                                selected = appDisplayMode == value,
                                onClick = {
                                    if (value != appDisplayMode) {
                                        appDisplayMode = value
                                        session.settings.setAppDisplayMode(installationId, appId, value)
                                        closeSheet()
                                        reload()
                                    }
                                },
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                            ) { Text(label) }
                        }
                }
                Spacer(Modifier.height(22.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column {
                        Text("显示悬浮按钮", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                        Text("共 ${buttons.size} 个按钮", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(
                        checked = buttonsVisible,
                        onCheckedChange = { checked ->
                            buttonsVisible = checked
                            session.settings.setFkButtonsVisible(installationId, appId, checked)
                        },
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = {
                            persistButtons(buttons + FloatingLayout.newButton())
                            buttonsVisible = true
                            session.settings.setFkButtonsVisible(installationId, appId, true)
                            editMode = true
                            closeSheet()
                        },
                        modifier = Modifier.weight(1f),
                        enabled = buttons.size < FloatingLayout.MAX_BUTTONS,
                    ) { Text("新建") }
                    OutlinedButton(
                        onClick = {
                            editMode = !editMode
                            closeSheet()
                        },
                        modifier = Modifier.weight(1f),
                    ) { Text(if (editMode) "完成编辑" else "编辑布局") }
                }
                Spacer(Modifier.height(22.dp))

                OutlinedButton(onClick = { reload(); closeSheet() }, modifier = Modifier.fillMaxWidth()) {
                    Text("重新加载页面")
                }
                Spacer(Modifier.height(10.dp))
                Button(onClick = { closeSheet(); onExitToCatalog() }, modifier = Modifier.fillMaxWidth()) {
                    Text("返回目录")
                }
            }
        }
    }
}

/** 边缘滑动触发区:从屏幕边缘向内水平拖动超过阈值即触发,不拦截点击与垂直滚动。 */
@Composable
private fun BoxScope.EdgeSwipeZone(alignment: Alignment, direction: Float, onTrigger: () -> Unit) {
    Box(
        Modifier
            .align(alignment)
            .fillMaxHeight()
            .width(28.dp)
            .pointerInput(direction) {
                var acc = 0f
                var triggered = false
                detectHorizontalDragGestures(
                    onDragStart = {
                        acc = 0f
                        triggered = false
                    },
                    onHorizontalDrag = { change, dragAmount ->
                        if (triggered) return@detectHorizontalDragGestures
                        acc += dragAmount
                        if (acc * direction > 56.dp.toPx()) {
                            triggered = true
                            change.consume()
                            onTrigger()
                        } else if (acc * direction > 8.dp.toPx()) {
                            change.consume()
                        }
                    },
                )
            },
    )
}

/** 为 WebView 声明手势排除区(左右边缘中部各一条,系统上限 200dp),让边缘滑动交给应用。 */
private fun applyGestureExclusion(view: View) {
    if (view.height == 0 || view.width == 0) {
        view.post { applyGestureExclusion(view) }
        return
    }
    val density = view.resources.displayMetrics.density
    val edge = (28 * density).toInt()
    val half = (100 * density).toInt()
    val centerY = view.height / 2
    ViewCompat.setSystemGestureExclusionRects(
        view,
        listOf(
            Rect(0, (centerY - half).coerceAtLeast(0), edge, centerY + half),
            Rect(view.width - edge, (centerY - half).coerceAtLeast(0), view.width, centerY + half),
        ),
    )
}
