package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.ui.CatalogUiState
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.components.AppCard
import com.remoteeverything.app.ui.components.CenteredLoading
import com.remoteeverything.app.ui.components.MessageCard
import com.remoteeverything.app.web.WebViewPool

/** 应用目录:状态横幅 + 应用卡片列表 + 下拉刷新;加载成功后预热 WebView 池。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CatalogScreen(
    session: SessionViewModel,
    pool: WebViewPool,
    onSettings: () -> Unit,
    onEnterApp: (String) -> Unit,
) {
    val catalog by session.catalog.collectAsStateWithLifecycle()
    val profile by session.activeProfile.collectAsStateWithLifecycle()
    var refreshing by remember { mutableStateOf(false) }

    LaunchedEffect(catalog) {
        refreshing = false
        val ready = catalog as? CatalogUiState.Ready ?: return@LaunchedEffect
        if (ready.snapshot.computerConnected) pool.warm(ready.snapshot.apps)
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
            isRefreshing = refreshing,
            onRefresh = {
                refreshing = true
                session.refreshCatalog()
            },
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
                            else -> items(snapshot.apps, key = { it.id }) { app ->
                                val config = profile
                                AppCard(
                                    app = app,
                                    canEnter = config != null && config.isGatewayUrl(app.openUrl),
                                    onPower = { session.controlApp(app, if (app.code == "stopped") "start" else "stop") },
                                    onEnter = { onEnterApp(app.id) },
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
