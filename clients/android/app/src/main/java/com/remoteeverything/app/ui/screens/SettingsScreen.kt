package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.PROJECT_URL
import com.remoteeverything.app.UpdateUiState
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.theme.THEME_DARK
import com.remoteeverything.app.ui.theme.THEME_LIGHT
import com.remoteeverything.app.ui.theme.THEME_SYSTEM

/** 设置:全局屏幕方向 + 连接入口。应用级方向在远程界面底部面板中单独设置。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    session: SessionViewModel,
    onBack: () -> Unit,
    onManageConnections: () -> Unit,
) {
    val profile by session.activeProfile.collectAsStateWithLifecycle()
    val updateState by session.updateState.collectAsStateWithLifecycle()
    var orientation by remember { mutableStateOf(session.settings.globalOrientation()) }
    var displayMode by remember { mutableStateOf(session.settings.globalDisplayMode()) }
    var themeMode by remember { mutableStateOf(session.settings.themeMode()) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                SectionLabel("屏幕方向")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf("system" to "跟随系统", "portrait" to "竖屏锁定", "landscape" to "横屏锁定")
                        .forEachIndexed { index, (value, label) ->
                            SegmentedButton(
                                selected = orientation == value,
                                onClick = {
                                    orientation = value
                                    session.settings.setGlobalOrientation(value)
                                },
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                            ) { Text(label) }
                        }
                }
            }
            item {
                SectionLabel("显示模式")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf("phone" to "手机", "desktop" to "电脑")
                        .forEachIndexed { index, (value, label) ->
                            SegmentedButton(
                                selected = displayMode == value,
                                onClick = {
                                    displayMode = value
                                    session.settings.setGlobalDisplayMode(value)
                                },
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                            ) { Text(label) }
                        }
                }
            }
            item {
                SectionLabel("主题")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf(THEME_SYSTEM to "跟随系统", THEME_LIGHT to "浅色", THEME_DARK to "深色")
                        .forEachIndexed { index, (value, label) ->
                            SegmentedButton(
                                selected = themeMode == value,
                                onClick = {
                                    themeMode = value
                                    session.setThemeMode(value)
                                },
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                            ) { Text(label) }
                        }
                }
            }
            item {
                SectionLabel("连接")
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(16.dp)) {
                        Text(
                            profile?.let { "${it.name} · ${if (it.mode == "lan") "局域网" else "公网"}" } ?: "未配置",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        if (profile != null) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                profile!!.gatewayOrigin,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.height(14.dp))
                        OutlinedButton(onClick = onManageConnections, modifier = Modifier.fillMaxWidth()) {
                            Text("管理连接")
                        }
                    }
                }
            }
            item {
                AboutAndUpdateCard(
                    state = updateState,
                    onCheck = session::checkForUpdate,
                    onDownload = session::downloadUpdate,
                    onInstall = { context -> session.installUpdate(context) },
                )
            }
        }
    }
}

@Composable
private fun AboutAndUpdateCard(
    state: UpdateUiState,
    onCheck: () -> Unit,
    onDownload: () -> Unit,
    onInstall: (android.content.Context) -> Unit,
) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    SectionLabel("关于与更新")
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Info,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Column(Modifier.padding(start = 12.dp)) {
                    Text("远程万物", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "版本 ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · ${if (BuildConfig.DEBUG) "开发版" else "正式版"}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(14.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Spacer(Modifier.height(14.dp))
            Text(
                updateDescription(state),
                style = MaterialTheme.typography.bodyMedium,
                color = if (state is UpdateUiState.Error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (state is UpdateUiState.Downloading) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = { state.progress },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(Modifier.height(14.dp))
            when (state) {
                UpdateUiState.Idle, is UpdateUiState.Current, is UpdateUiState.Error ->
                    Button(onClick = onCheck, modifier = Modifier.fillMaxWidth()) { Text("检查更新") }
                UpdateUiState.Checking ->
                    Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) { Text("正在检查…") }
                is UpdateUiState.Available -> if (state.installable) {
                    Button(onClick = onDownload, modifier = Modifier.fillMaxWidth()) { Text("下载并校验 ${state.release.tagName}") }
                } else {
                    Button(onClick = { uriHandler.openUri(state.release.pageUrl) }, modifier = Modifier.fillMaxWidth()) { Text("查看正式发布版") }
                }
                is UpdateUiState.Downloading ->
                    Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) {
                        Text("正在下载 ${(state.progress * 100).toInt()}%")
                    }
                is UpdateUiState.Ready ->
                    Button(onClick = { onInstall(context) }, modifier = Modifier.fillMaxWidth()) { Text("安装 ${state.release.tagName}") }
            }
            TextButton(
                onClick = { uriHandler.openUri(PROJECT_URL) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("查看 GitHub 项目")
                Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, modifier = Modifier.padding(start = 6.dp))
            }
        }
    }
}

private fun updateDescription(state: UpdateUiState): String = when (state) {
    UpdateUiState.Idle -> "从项目正式发布页检查新版本。下载后会验证摘要、包名、版本与签名。"
    UpdateUiState.Checking -> "正在查询最新正式发布版…"
    is UpdateUiState.Current -> if (state.currentIsNewer) {
        "当前版本高于最新正式版 ${state.latestVersion}。"
    } else {
        "当前已是最新正式版 ${state.latestVersion}。"
    }
    is UpdateUiState.Available -> if (state.installable) {
        "发现新版本 ${state.release.versionName}，可在应用内安全下载并安装。"
    } else {
        "发现新版本 ${state.release.versionName}，但当前是开发签名版本，不能直接覆盖正式版。"
    }
    is UpdateUiState.Downloading -> "正在下载 ${state.release.versionName}，完成后会执行安全校验。"
    is UpdateUiState.Ready -> "${state.release.versionName} 已下载并通过安全校验，可以交给系统安装。"
    is UpdateUiState.Error -> state.detail
}

@Composable
internal fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
    )
}
