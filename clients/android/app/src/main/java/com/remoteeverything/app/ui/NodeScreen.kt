package com.remoteeverything.app.ui

import com.remoteeverything.app.i18n.l10n
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.AppModel
import com.remoteeverything.app.web.AppWebActivity
import com.remoteeverything.app.CatalogUiState
import com.remoteeverything.app.theme.LocalSemanticColors
import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.AppState
import com.remoteeverything.core.model.LinkKind
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.NodeStatus
import com.remoteeverything.core.model.Path
import com.remoteeverything.core.store.Appearance
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NodeScreen(vm: AppModel, nodeId: String, onBack: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val node = state.nodes.firstOrNull { it.id == nodeId }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(node?.name ?: "", style = MaterialTheme.typography.titleMedium)
                        // Under its own name, whose screen this is, and which way the
                        // phone is getting there.
                        val status = node?.let { vm.statusOf(it) }
                        if (status != null) {
                            Text(
                                currentPathHint(node?.let { vm.pathFor(it) }) ?: statusLabel(status),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = l10n(MessageKeys.ACTION_BACK),
                        )
                    }
                },
            )
        },
    ) { padding ->
        NodeContent(vm = vm, nodeId = nodeId, onGone = onBack, modifier = Modifier.padding(padding))
    }
}

/**
 * One node's applications, without deciding what is around them: the phone puts
 * a back arrow above this and the wide screen puts it beside the list.
 */
@Composable
fun NodeContent(vm: AppModel, nodeId: String, onGone: () -> Unit, modifier: Modifier = Modifier) {
    val state by vm.state.collectAsStateWithLifecycle()
    val node = state.nodes.firstOrNull { it.id == nodeId }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var openingAppId by remember { mutableStateOf<String?>(null) }
    val dark = when (state.settings.appearance) {
        Appearance.SYSTEM -> isSystemInDarkTheme()
        Appearance.LIGHT -> false
        Appearance.DARK -> true
    }

    LaunchedEffect(nodeId) {
        node?.let { vm.watchNode(it) }
    }
    DisposableEffect(nodeId) {
        onDispose { vm.stopWatching() }
    }
    NoticeEffect(snackbar, state.notice, vm::consumeNotice)
    val openFailed = l10n(MessageKeys.APP_OPEN_FAILED)

    Scaffold(modifier = modifier, snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        val current = node
        when {
            current == null -> CenteredMessage(
                title = l10n(MessageKeys.ERROR_NODE_GONE),
                body = l10n(MessageKeys.ERROR_NODE_GONE_BODY),
                action = l10n(MessageKeys.ACTION_BACK_TO_NODES),
                onAction = {
                    vm.refreshNodes()
                    onGone()
                },
                modifier = Modifier.padding(padding),
            )
            else -> when (val catalog = state.catalog) {
                CatalogUiState.Loading -> Box(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator() }

                CatalogUiState.Offline -> CenteredMessage(
                    title = l10n(MessageKeys.NODE_OFFLINE_TITLE),
                    body = l10n(MessageKeys.NODE_OFFLINE_BODY),
                    action = l10n(MessageKeys.ACTION_RETRY),
                    // Asking again means asking now: the node list is read again and
                    // this node's catalog with it, so the screen says it is trying
                    // instead of staying exactly as it was.
                    onAction = { vm.retryNode(current) },
                    modifier = Modifier.padding(padding),
                )

                CatalogUiState.Unauthorized -> CenteredMessage(
                    title = l10n(MessageKeys.ERROR_NODE_GONE),
                    body = l10n(MessageKeys.ERROR_NODE_GONE_BODY),
                    action = l10n(MessageKeys.ACTION_BACK_TO_NODES),
                    onAction = {
                        vm.refreshNodes()
                        onGone()
                    },
                    modifier = Modifier.padding(padding),
                )

                is CatalogUiState.Failed -> CenteredMessage(
                    title = l10n(MessageKeys.PAIR_GATEWAY_TROUBLE),
                    action = l10n(MessageKeys.ACTION_RETRY),
                    onAction = { vm.retryNode(current) },
                    modifier = Modifier.padding(padding),
                )

                is CatalogUiState.Ready -> {
                    if (catalog.apps.isEmpty()) {
                        CenteredMessage(
                            title = l10n(MessageKeys.APPS_EMPTY_TITLE),
                            body = l10n(MessageKeys.APPS_EMPTY_BODY),
                            modifier = Modifier.padding(padding),
                        )
                    } else {
                        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding)) {
                            items(catalog.apps, key = { it.id }) { app ->
                                AppRow(
                                    app = app,
                                    isOpening = openingAppId == app.id,
                                    onOpen = {
                                        if (openingAppId == null) {
                                            openingAppId = app.id
                                            scope.launch {
                                                val target = vm.open(current, app.id)
                                                val identityOrigin = vm.originFor(current)
                                                if (target == null || identityOrigin == null) {
                                                    snackbar.showSnackbar(openFailed)
                                                } else {
                                                    context.startActivity(
                                                        AppWebActivity.intent(
                                                            context = context,
                                                            url = target.url + app.launchFragment,
                                                            identityOrigin = identityOrigin,
                                                            appKey = "${current.id}/${app.id}",
                                                            serverPin = target.serverPin,
                                                            dark = dark,
                                                        ),
                                                    )
                                                }
                                                openingAppId = null
                                            }
                                        }
                                    },
                                    onControl = { start -> vm.control(current, app.id, start) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AppRow(
    app: AppInfo,
    isOpening: Boolean = false,
    onOpen: () -> Unit,
    onControl: (Boolean) -> Unit,
) {
    val semantic = LocalSemanticColors.current
    val accent = remember(app.accent) {
        runCatching { Color(android.graphics.Color.parseColor(app.accent)) }.getOrDefault(semantic.offline)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(72.dp)
            .clickable(enabled = !isOpening && (app.code != AppState.STOPPED || app.enabled), onClick = onOpen)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(40.dp),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = accent.copy(alpha = 0.12f),
                modifier = Modifier.size(40.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(app.icon.ifEmpty { "📦" }, style = MaterialTheme.typography.titleMedium)
                }
            }
        }
        Column(modifier = Modifier.weight(1f).padding(start = 12.dp)) {
            Text(app.name, style = MaterialTheme.typography.titleMedium)
            if (app.description.isNotEmpty()) {
                Text(
                    app.description,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
        if (isOpening) {
            CircularProgressIndicator(modifier = Modifier.size(24.dp).padding(2.dp), strokeWidth = 2.dp)
        } else {
            val (stateLabel, stateColor) = when (app.code) {
                AppState.READY -> l10n(MessageKeys.forAppState(app.code)) to semantic.ok
                AppState.STARTING -> l10n(MessageKeys.forAppState(app.code)) to semantic.warn
                AppState.STOPPING -> l10n(MessageKeys.forAppState(app.code)) to semantic.warn
                AppState.STOPPED -> l10n(MessageKeys.forAppState(app.code)) to semantic.offline
            }
            StatusChip(stateLabel, stateColor)
        }
        val busy = app.code == AppState.STARTING || app.code == AppState.STOPPING
        if (busy) {
            // A request is in flight: the row shows that rather than a button
            // that would send it a second time.
            Box(modifier = Modifier.size(52.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        } else {
            TextButton(onClick = { onControl(app.code == AppState.STOPPED) }) {
                Text(l10n(if (app.code == AppState.STOPPED) MessageKeys.ACTION_START else MessageKeys.ACTION_STOP))
            }
        }
    }
}

@Composable
internal fun statusLabel(status: NodeStatus): String = l10n(MessageKeys.forNodeStatus(status))

/**
 * The one-line answer to "which way am I going in": local link or tunnel, said
 * with the same words the row uses. A machine nothing answers for has no path to
 * describe, and its own screen already says so.
 */
@Composable
internal fun currentPathHint(path: Path?): String? = when (path?.link) {
    LinkKind.LOCAL -> l10n(MessageKeys.NODE_CURRENT_LAN)
    LinkKind.TUNNEL -> l10n(MessageKeys.NODE_CURRENT_TUNNEL)
    null -> null
}

/** Shows whatever the app has to say, once, wherever the screen is. */
@Composable
internal fun NoticeEffect(snackbar: SnackbarHostState, notice: Int?, onConsumed: () -> Unit) {
    val message = notice?.let { stringResource(it) }
    LaunchedEffect(notice) {
        if (message != null) {
            snackbar.showSnackbar(message)
            onConsumed()
        }
    }
}
