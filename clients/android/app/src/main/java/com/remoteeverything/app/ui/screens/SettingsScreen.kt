package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.ui.SessionViewModel

/** 设置:全局屏幕方向 + 连接入口。应用级方向在远程界面底部面板中单独设置。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    session: SessionViewModel,
    onBack: () -> Unit,
    onManageConnections: () -> Unit,
) {
    val profile by session.activeProfile.collectAsStateWithLifecycle()
    var orientation by remember { mutableStateOf(session.settings.globalOrientation()) }
    var displayMode by remember { mutableStateOf(session.settings.globalDisplayMode()) }

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
        }
    }
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
