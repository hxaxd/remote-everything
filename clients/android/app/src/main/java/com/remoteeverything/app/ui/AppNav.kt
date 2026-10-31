package com.remoteeverything.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.AppModel

@Composable
fun AppNav(vm: AppModel) {
    var destination by rememberSaveable { mutableStateOf("home") }
    val saved = rememberSaveableStateHolder()
    val wide = LocalConfiguration.current.screenWidthDp >= WideScreenDp
    val invitation by vm.pendingInvitation.collectAsStateWithLifecycle()
    val back = { destination = "home" }
    BackHandler(destination != "home") { back() }
    LaunchedEffect(invitation) { if (!invitation.isNullOrBlank()) destination = "pair" }
    val detail: @Composable (Boolean) -> Unit = { embedded ->
        saved.SaveableStateProvider(destination) {
            when {
                destination == "pair" -> PairScreen(vm,onBack = back,embedded = embedded)
                destination == "settings" -> SettingsScreen(vm,onBack = back,embedded = embedded)
                destination.startsWith("node/") -> NodeScreen(vm,nodeId = destination.removePrefix("node/"),onBack = back,embedded = embedded)
                else -> CenteredMessage(title = l10nForSelection())
            }
        }
    }
    if (wide || destination == "home") {
        HomeScreen(vm = vm,
            onAdd = { saved.removeState("pair"); vm.beginPairing(); destination = "pair" },
            onSettings = { destination = "settings" },
            onNode = { destination = "node/${it.id}" },
            selected = destination.takeIf { it.startsWith("node/") }?.removePrefix("node/"),
            detail = { detail(true) })
    } else { detail(false) }
}

@Composable
private fun l10nForSelection() = com.remoteeverything.app.i18n.l10n(com.remoteeverything.core.model.MessageKeys.NODES_SELECT_HINT)
