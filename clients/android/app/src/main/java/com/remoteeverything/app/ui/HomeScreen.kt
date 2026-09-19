package com.remoteeverything.app.ui

import com.remoteeverything.app.i18n.l10n
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.AppModel
import com.remoteeverything.app.PairingUiState
import com.remoteeverything.app.theme.LocalSemanticColors
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.NodeStatus
import com.remoteeverything.core.model.Path

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(vm: AppModel, onAdd: () -> Unit, onSettings: () -> Unit, onNode: (Node) -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val semantic = LocalSemanticColors.current
    // A screen wide enough for two panes shows the list and a node's
    // applications side by side; anything narrower keeps one pane and a back arrow.
    val wide = LocalConfiguration.current.screenWidthDp >= WideScreenDp
    var selected by rememberSaveable { mutableStateOf<String?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(l10n(MessageKeys.APP_NAME)) },
                actions = {
                    IconButton(onClick = { vm.refreshNodes() }) {
                        Icon(Icons.Default.Refresh, contentDescription = l10n(MessageKeys.SETTINGS_UPDATES_CHECK))
                    }
                    IconButton(onClick = onAdd) {
                        Icon(Icons.Default.Add, contentDescription = l10n(MessageKeys.ACTION_ADD_NODE))
                    }
                    IconButton(onClick = onSettings) {
                        Icon(Icons.Default.Settings, contentDescription = l10n(MessageKeys.SETTINGS_TITLE))
                    }
                },
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = { vm.refreshNodes() },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                val pairing = state.pairing
                if (pairing is PairingUiState.Pending) {
                    // A device that paired but is not approved yet: saying so is the
                    // difference between "it did not work" and "it is waiting".
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        StatusChip(l10n(MessageKeys.NODE_PENDING), semantic.warn)
                        Text(
                            pairing.nodeName,
                            style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier.weight(1f).padding(start = 12.dp),
                        )
                        Button(onClick = { vm.resumePendingPairing() }) { Text(l10n(MessageKeys.ACTION_RETRY)) }
                    }
                }
                if (state.nodes.isEmpty()) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(24.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(l10n(MessageKeys.EMPTY_TITLE), style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(8.dp))
                        Text(
                            l10n(MessageKeys.EMPTY_BODY),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(24.dp))
                        Button(onClick = onAdd) { Text(l10n(MessageKeys.ACTION_ADD_NODE)) }
                    }
                } else if (wide) {
                    Row(modifier = Modifier.fillMaxSize()) {
                        NodeList(
                            vm = vm,
                            state = state,
                            selectedId = selected,
                            onSelect = { node -> selected = node.id },
                            modifier = Modifier.weight(0.42f),
                        )
                        VerticalDivider()
                        Box(modifier = Modifier.weight(0.58f)) {
                            val nodeId = selected
                            if (nodeId == null) {
                                CenteredMessage(
                                    title = l10n(MessageKeys.NODES_SELECT_HINT),
                                )
                            } else {
                                NodeContent(vm = vm, nodeId = nodeId, onGone = { selected = null })
                            }
                        }
                    }
                } else {
                    NodeList(
                        vm = vm,
                        state = state,
                        selectedId = null,
                        onSelect = { node -> onNode(node) },
                    )
                }
            }
        }
    }
}

@Composable
private fun NodeList(
    vm: AppModel,
    state: com.remoteeverything.app.AppUiState,
    selectedId: String?,
    onSelect: (Node) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(modifier = modifier.fillMaxSize()) {
        items(state.nodes, key = { it.id }) { node ->
            NodeRow(
                node = node,
                status = vm.statusOf(node),
                inUse = vm.pathFor(node),
                selected = node.id == selectedId,
                onClick = { onSelect(node) },
            )
        }
    }
}

private const val WideScreenDp = 840

/**
 * One machine, as a row of its own: its name, and how this phone reaches it —
 * the same card the settings give a connection, because it is the same kind of
 * thing. The right-hand side says what the link *is* (a local link, a link over
 * the tunnel, or nothing answering), which is one answer even when the phone
 * holds several ways in: the one it would actually take.
 */
@Composable
private fun NodeRow(
    node: Node,
    status: NodeStatus,
    inUse: Path?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val semantic = LocalSemanticColors.current
    val (label, color) = when (status) {
        NodeStatus.ONLINE_LAN -> l10n(MessageKeys.forNodeStatus(status)) to semantic.ok
        NodeStatus.ONLINE_TUNNEL -> l10n(MessageKeys.forNodeStatus(status)) to semantic.ok
        NodeStatus.OFFLINE -> l10n(MessageKeys.forNodeStatus(status)) to semantic.offline
        NodeStatus.PENDING_APPROVAL -> l10n(MessageKeys.forNodeStatus(status)) to semantic.warn
        NodeStatus.UNKNOWN -> l10n(MessageKeys.forNodeStatus(status)) to semantic.offline
    }
    Surface(
        color = if (selected) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.08f)
        } else {
            MaterialTheme.colorScheme.surface
        },
        shape = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(64.dp)
                .clickable(onClick = onClick)
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                node.name,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
                color = if (status == NodeStatus.OFFLINE) semantic.textTertiary else MaterialTheme.colorScheme.onSurface,
            )
            // Which ways in this phone has, and which one it would take: a machine
            // waited on by a person is a machine with more than one answer.
            if (status == NodeStatus.PENDING_APPROVAL || status == NodeStatus.UNKNOWN) {
                StatusChip(label, color)
            } else {
                LinkChips(paths = node.paths, inUse = if (status == NodeStatus.OFFLINE) null else inUse)
            }
        }
    }
}


