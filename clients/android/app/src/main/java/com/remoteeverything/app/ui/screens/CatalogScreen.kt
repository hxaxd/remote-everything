package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.RemoteApp
import com.remoteeverything.app.ui.CatalogUiState
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.components.AppCard
import com.remoteeverything.app.ui.components.CenteredLoading
import com.remoteeverything.app.ui.components.MessageCard

/** 应用目录:状态横幅 + 应用卡片列表 + 下拉刷新 + 长按拖拽排序。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CatalogScreen(
    session: SessionViewModel,
    onSettings: () -> Unit,
    onEnterApp: (RemoteApp) -> Unit,
) {
    val catalog by session.catalog.collectAsStateWithLifecycle()
    val refreshing by session.catalogRefreshing.collectAsStateWithLifecycle()
    val profile by session.activeProfile.collectAsStateWithLifecycle()
    var pendingStop by remember { mutableStateOf<RemoteApp?>(null) }

    // 拖拽排序状态
    var draggedIndex by remember { mutableIntStateOf(-1) }
    var dragOffset by remember { mutableFloatStateOf(0f) }

    // 自定义排序持久化
    val installationId = profile?.installationId
    var savedOrder by remember(installationId) {
        mutableStateOf(installationId?.let { session.settings.appOrder(it) } ?: emptyList())
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("远程万物")
                        Text(
                            profile?.name ?: "",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "设置")
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        PullToRefreshBox(
            // 下拉圆形指示器只表示手势本身，释放后立即收起；实际请求用顶部进度条表示。
            // 这样即使系统动画状态异常，也不会出现永久转圈遮住目录。
            isRefreshing = false,
            onRefresh = session::refreshCatalog,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when (val state = catalog) {
                    is CatalogUiState.Loading -> item { CenteredLoading() }
                    is CatalogUiState.Error -> item {
                        MessageCard(
                            title = "目录暂时不可用",
                            detail = "连接失败:${state.detail}\n\n应用会自动重试,也可下拉手动刷新。",
                            icon = {
                                Icon(
                                    Icons.Filled.Warning,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(36.dp).padding(bottom = 12.dp),
                                )
                            },
                        )
                    }
                    is CatalogUiState.Ready -> {
                        val snapshot = state.snapshot
                        when {
                            !snapshot.computerConnected || snapshot.code == "computer_offline" -> item {
                                MessageCard(
                                    title = "节点离线",
                                    detail = "服务入口仍可连接,但节点核心当前不可用。应用会自动重试。",
                                    icon = {
                                        Icon(
                                            Icons.Filled.CloudOff,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.size(36.dp).padding(bottom = 12.dp),
                                        )
                                    },
                                )
                            }
                            snapshot.apps.isEmpty() -> item {
                                MessageCard(
                                    title = "还没有已注册的应用",
                                    detail = "在电脑上注册应用后会自动出现在这里。",
                                    icon = {
                                        Icon(
                                            Icons.Filled.Inbox,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.size(36.dp).padding(bottom = 12.dp),
                                        )
                                    },
                                )
                            }
                            else -> {
                                val apps = snapshot.apps
                                val ordered = if (savedOrder.isEmpty()) apps else {
                                    val ranks = savedOrder.withIndex().associate { it.value to it.index }
                                    apps.sortedBy { ranks[it.id] ?: Int.MAX_VALUE }
                                }

                                itemsIndexed(ordered, key = { _, app -> app.id }) { index, app ->
                                    val isDragging = draggedIndex == index
                                    val canEnter = profile?.isGatewayUrl(app.openUrl) ?: false
                                    AppCard(
                                        app = app,
                                        canEnter = canEnter,
                                        onPower = {
                                            if (app.code == "ready") pendingStop = app
                                            else session.controlApp(app, "start")
                                        },
                                        onEnter = { onEnterApp(app) },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .zIndex(if (isDragging) 1f else 0f)
                                            .graphicsLayer {
                                                if (isDragging) translationY = dragOffset
                                            }
                                            .pointerInput(app.id) {
                                                detectDragGesturesAfterLongPress(
                                                    onDragStart = {
                                                        draggedIndex = index
                                                        dragOffset = 0f
                                                    },
                                                    onDrag = { change, dragAmount ->
                                                        change.consume()
                                                        dragOffset += dragAmount.y
                                                        // PointerInputScope 实现 Density:160dp 约为 AppCard+间距
                                                        val itemH = 160.dp.toPx()
                                                        val steps = (dragOffset / itemH).toInt()
                                                        if (steps != 0) {
                                                            val newIndex = (index + steps).coerceIn(0, ordered.lastIndex)
                                                            if (newIndex != index) {
                                                                val newList = ordered.toMutableList()
                                                                val moved = newList.removeAt(index)
                                                                newList.add(newIndex, moved)
                                                                savedOrder = newList.map { it.id }
                                                                installationId?.let { session.settings.setAppOrder(it, savedOrder) }
                                                                draggedIndex = newIndex
                                                                dragOffset = 0f
                                                            }
                                                        }
                                                    },
                                                    onDragEnd = {
                                                        draggedIndex = -1
                                                        dragOffset = 0f
                                                    },
                                                    onDragCancel = {
                                                        draggedIndex = -1
                                                        dragOffset = 0f
                                                    },
                                                )
                                            },
                                    )
                                }
                            }
                        }
                    }
                }
            }
            if (refreshing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }
    }

    pendingStop?.let { app ->
        AlertDialog(
            onDismissRequest = { pendingStop = null },
            title = { Text("停止 ${app.name}") },
            text = { Text("确定要停止「${app.name}」吗？停止后需要重新启动才能进入。") },
            confirmButton = {
                TextButton(onClick = {
                    session.controlApp(app, "stop")
                    pendingStop = null
                }) { Text("停止", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingStop = null }) { Text("取消") }
            },
        )
    }
}
