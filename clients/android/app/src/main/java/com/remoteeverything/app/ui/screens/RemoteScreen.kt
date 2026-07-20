package com.remoteeverything.app.ui.screens

import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.data.FloatingLayout
import com.remoteeverything.app.data.FloatingPanel
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

    var panels by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.fkPanels(it, appId) } ?: emptyList())
    }
    var panelsVisible by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.fkPanelsVisible(it, appId) } ?: true)
    }
    var appOrientation by remember(installationId, appId) {
        mutableStateOf(installationId?.let { session.settings.appOrientation(it, appId) } ?: "global")
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

    fun persistPanels(next: List<FloatingPanel>) {
        panels = next
        session.settings.setFkPanels(installationId, appId, next)
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
                factory = { entry.webView },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (progress < 100) {
            LinearProgressIndicator(
                progress = { progress / 100f },
                modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter),
            )
        }

        if (panelsVisible && panels.isNotEmpty()) {
            FloatingPanelLayer(
                panels = panels,
                editMode = editMode,
                onKey = { injector.inject(it) },
                onCommit = ::persistPanels,
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
                    "编辑悬浮布局 · 点这里完成",
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
                Spacer(Modifier.height(4.dp))
                Text("选项", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(20.dp))

                SectionLabel("屏幕方向(本应用)")
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

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column {
                        Text("显示悬浮面板", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                        Text("共 ${panels.size} 个面板", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(
                        checked = panelsVisible,
                        onCheckedChange = { checked ->
                            panelsVisible = checked
                            session.settings.setFkPanelsVisible(installationId, appId, checked)
                        },
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = {
                            persistPanels(panels + FloatingLayout.defaultPanel())
                            panelsVisible = true
                            session.settings.setFkPanelsVisible(installationId, appId, true)
                            editMode = true
                            closeSheet()
                        },
                        modifier = Modifier.weight(1f),
                        enabled = panels.size < FloatingLayout.MAX_PANELS,
                    ) { Text("新建面板") }
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
