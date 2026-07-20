package com.remoteeverything.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt
import com.remoteeverything.app.RemoteApp
import com.remoteeverything.app.ui.theme.semantic

fun statusLabel(code: String): String = when (code) {
    "ready" -> "正在运行"
    "starting" -> "正在启动"
    "stopping" -> "正在停止"
    "stopped" -> "已停止"
    "computer_offline" -> "电脑离线"
    else -> "状态不可用"
}

@Composable
fun StatusChip(code: String, modifier: Modifier = Modifier) {
    val semantic = MaterialTheme.semantic
    val (dot, container, onContainer) = when (code) {
        "ready" -> Triple(semantic.ok, semantic.okContainer, semantic.onOkContainer)
        "starting", "stopping", "stopped" -> Triple(semantic.warn, semantic.warnContainer, semantic.onWarnContainer)
        "computer_offline" -> Triple(MaterialTheme.colorScheme.onSurfaceVariant, MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.colorScheme.onSurfaceVariant)
        else -> Triple(MaterialTheme.colorScheme.error, MaterialTheme.colorScheme.errorContainer, MaterialTheme.colorScheme.onErrorContainer)
    }
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.small,
        color = container,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(shape = androidx.compose.foundation.shape.CircleShape, color = dot, modifier = Modifier.size(7.dp)) {}
            Spacer(Modifier.width(6.dp))
            Text(statusLabel(code), style = MaterialTheme.typography.labelMedium, color = onContainer)
        }
    }
}

@Composable
fun AppCard(
    app: RemoteApp,
    canEnter: Boolean,
    onPower: () -> Unit,
    onEnter: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = runCatching { Color(app.accent.toColorInt()) }
        .getOrDefault(MaterialTheme.colorScheme.primary)
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = accent,
                    modifier = Modifier.size(48.dp),
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Text(
                            app.icon.take(4),
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White,
                            maxLines = 1,
                        )
                    }
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        app.name,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(6.dp))
                    StatusChip(app.code)
                }
            }
            if (app.description.isNotBlank()) {
                Spacer(Modifier.height(12.dp))
                Text(
                    app.description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val powerEnabled = app.code == "ready" || app.code == "stopped"
                OutlinedButton(
                    onClick = onPower,
                    enabled = powerEnabled,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (app.code == "stopped") "启动" else "停止")
                }
                Button(
                    onClick = onEnter,
                    enabled = canEnter && app.code == "ready",
                    modifier = Modifier.weight(1f),
                ) {
                    Text("进入")
                }
            }
        }
    }
}

@Composable
fun MessageCard(
    title: String,
    detail: String,
    modifier: Modifier = Modifier,
    icon: @Composable () -> Unit = {},
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            icon()
            Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(8.dp))
            Text(
                detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

@Composable
fun CenteredLoading(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
    }
}
