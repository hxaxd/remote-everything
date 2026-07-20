package com.remoteeverything.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.connectionActionLabel
import com.remoteeverything.app.ui.SessionViewModel
import kotlinx.coroutines.launch

/**
 * 连接管理:已有连接列表 + 新增(扫码/粘贴)。
 * 是独立路由,返回键可正常回到来处(修复旧版"管理连接无法返回")。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionsScreen(
    session: SessionViewModel,
    canPopBack: Boolean,
    onBack: () -> Unit,
    onOpenCatalog: () -> Unit,
    onBeginWizard: () -> Unit,
) {
    val profiles by session.profiles.collectAsStateWithLifecycle()
    val active by session.activeProfile.collectAsStateWithLifecycle()
    var setupLink by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var pendingDelete by remember { mutableStateOf<ConnectionConfig?>(null) }
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val scanLauncher = androidx.activity.compose.rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@rememberLauncherForActivityResult
        val error = session.beginSetup(contents)
        if (error != null) status = error else onBeginWizard()
    }

    fun submit(value: String) {
        val link = value.trim()
        if (link.isNotEmpty()) {
            val error = session.beginSetup(link)
            if (error != null) status = error else onBeginWizard()
            return
        }
        scope.launch {
            val clipText = clipboard.getClipEntry()?.clipData
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)?.coerceToText(context)?.toString()?.trim().orEmpty()
            if (clipText.isEmpty()) {
                status = "剪贴板中没有初始化链接"
                return@launch
            }
            setupLink = clipText
            val error = session.beginSetup(clipText)
            if (error != null) status = error else onBeginWizard()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("连接") },
                navigationIcon = {
                    if (canPopBack) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                        }
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(
                    "扫描电脑端 Agent 展示的初始化二维码,或粘贴初始化链接",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                Button(onClick = {
                    scanLauncher.launch(
                        ScanOptions()
                            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            .setPrompt("扫描 Remote Everything 初始化二维码")
                            .setBeepEnabled(false)
                            .setOrientationLocked(false),
                    )
                }, modifier = Modifier.fillMaxWidth().height(50.dp)) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("扫描连接")
                }
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = setupLink,
                    onValueChange = { setupLink = it; if (status.isNotEmpty()) status = "" },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("或粘贴一条初始化链接") },
                    singleLine = true,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedButton(
                    onClick = { submit(setupLink) },
                    modifier = Modifier.fillMaxWidth().height(46.dp),
                ) {
                    Text(connectionActionLabel(setupLink))
                }
                if (status.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
                }
            }

            if (profiles.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(14.dp))
                    Text(
                        "已有连接",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                items(profiles, key = { it.installationId }) { profile ->
                    ProfileRow(
                        profile = profile,
                        active = active?.installationId == profile.installationId,
                        usable = profile.mode != "public" || session.identity.hasCredential(profile.installationId),
                        onSelect = {
                            session.selectProfile(profile)
                            onOpenCatalog()
                        },
                        onUnusable = { status = "该连接缺少设备身份,请重新扫描初始化二维码" },
                        onDelete = { pendingDelete = profile },
                    )
                }
            }
        }
    }

    pendingDelete?.let { profile ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("删除 ${profile.name}?") },
            text = {
                Text(
                    if (profile.mode == "public") "删除本机保存的连接和设备私钥。服务器上的设备记录应由部署 Agent 同时吊销。"
                    else "删除本机保存的连接。",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    session.deleteProfile(profile)
                    pendingDelete = null
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun ProfileRow(
    profile: ConnectionConfig,
    active: Boolean,
    usable: Boolean,
    onSelect: () -> Unit,
    onUnusable: () -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        onClick = { if (usable) onSelect() else onUnusable() },
        shape = MaterialTheme.shapes.medium,
        color = if (active) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
        else MaterialTheme.colorScheme.surfaceContainerLow,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (active) MaterialTheme.colorScheme.primary.copy(alpha = 0.5f) else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        profile.name,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (active) {
                        Spacer(Modifier.width(8.dp))
                        Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.primaryContainer) {
                            Text(
                                "当前",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(
                    "${if (profile.mode == "lan") "局域网" else "公网"} · ${profile.gatewayOrigin}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Filled.Delete, contentDescription = "删除", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
