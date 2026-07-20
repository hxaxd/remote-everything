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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.HourglassTop
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.SetupAction
import com.remoteeverything.app.SetupState
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.StartState

/**
 * 初始化向导:配对 → 激活 → 等待批准 → 完成。
 * 每一步都有明确的状态、说明与可取消出口(修复旧版生命周期不可感知问题)。
 */
@Composable
fun SetupWizardScreen(
    session: SessionViewModel,
    onCompleted: () -> Unit,
    onCancel: () -> Unit,
) {
    val state by session.setupState.collectAsStateWithLifecycle()
    val start by session.startState.collectAsStateWithLifecycle()
    val pending = (start as? StartState.PendingActivation)?.config

    // 离开向导(返回/取消/完成)即终止后台事务;完成时事务已自行清理,此为幂等兜底
    DisposableEffect(Unit) {
        onDispose { session.cancelSetup() }
    }

    // 从启动恢复进入向导:尚未有向导状态时恢复激活
    LaunchedEffect(pending) {
        if (pending != null && session.setupState.value == null) {
            session.resumeActivation(pending)
        }
    }
    LaunchedEffect(state) {
        if (state is SetupState.Ready) onCompleted()
    }

    Scaffold(containerColor = MaterialTheme.colorScheme.background) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(36.dp))
            StepIndicator(state)
            Spacer(Modifier.height(48.dp))

            when (val current = state) {
                null -> Unit
                is SetupState.Pairing -> WizardBody(
                    icon = Icons.Filled.Sync,
                    title = "正在验证连接",
                    detail = if (current.config.mode == "public") "正在验证邀请并申请设备身份…" else "正在验证节点证书和应用目录…",
                    running = true,
                )
                is SetupState.Activating -> WizardBody(
                    icon = Icons.Filled.VerifiedUser,
                    title = "正在验证完整链路",
                    detail = "设备身份已签发,正在验证完整链路…",
                    running = true,
                )
                is SetupState.AwaitingApproval -> WizardBody(
                    icon = Icons.Filled.HourglassTop,
                    title = "等待人工批准",
                    detail = "设备申请已提交。请在电脑端 Agent 中核对设备名与完整指纹后批准;应用会自动重试,无需任何操作。",
                    running = true,
                )
                is SetupState.Ready -> WizardBody(
                    icon = Icons.Filled.CheckCircle,
                    title = "连接已完成",
                    detail = "正在进入应用目录…",
                    running = false,
                )
                is SetupState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    WizardBody(
                        icon = Icons.Filled.ErrorOutline,
                        title = "连接失败",
                        detail = current.message,
                        running = false,
                        error = true,
                    )
                    Spacer(Modifier.height(28.dp))
                    Button(onClick = { session.retrySetup() }, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                        Text(
                            when (current.action) {
                                SetupAction.RETRY_PAIRING -> "重试配对"
                                SetupAction.RETRY_ACTIVATION -> "重试激活"
                                SetupAction.RESTART_SETUP -> "重新初始化"
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.weight(1f))
            TextButton(
                onClick = {
                    session.cancelSetup()
                    onCancel()
                },
                modifier = Modifier.padding(bottom = 24.dp),
            ) {
                Text("取消并返回")
            }
        }
    }
}

@Composable
private fun StepIndicator(state: SetupState?) {
    val current = when (state) {
        is SetupState.Pairing -> 0
        is SetupState.Activating -> 1
        is SetupState.AwaitingApproval -> 2
        is SetupState.Ready -> 3
        else -> -1
    }
    val labels = listOf("验证连接", "签发身份", "等待批准")
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        labels.forEachIndexed { index, label ->
            val reached = current > index || (current == 3)
            val active = current == index
            Surface(
                shape = MaterialTheme.shapes.small,
                color = when {
                    reached || active -> MaterialTheme.colorScheme.primary
                    else -> MaterialTheme.colorScheme.surfaceContainerHigh
                },
                modifier = Modifier.weight(1f),
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (reached || active) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun WizardBody(
    icon: ImageVector,
    title: String,
    detail: String,
    running: Boolean,
    error: Boolean = false,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Surface(
            shape = androidx.compose.foundation.shape.CircleShape,
            color = if (error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.primaryContainer,
            modifier = Modifier.size(88.dp),
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = if (error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(40.dp),
                )
            }
        }
        Spacer(Modifier.height(24.dp))
        Text(title, style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.height(12.dp))
        Text(
            detail,
            style = MaterialTheme.typography.bodyLarge,
            color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (running) {
            Spacer(Modifier.height(28.dp))
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth(0.6f))
        }
    }
}
