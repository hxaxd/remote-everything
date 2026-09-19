package com.remoteeverything.app.ui

import com.remoteeverything.app.i18n.l10n
import android.content.ClipData
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.remoteeverything.app.AppModel
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.UpdateUiState
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.store.Appearance
import com.remoteeverything.core.store.Language

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(vm: AppModel, onBack: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val update by vm.updateState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val clipboard = LocalClipboard.current
    val copied = l10n(MessageKeys.ACTION_COPIED)

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text(l10n(MessageKeys.SETTINGS_TITLE)) },
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
        // Copying is what a person does with an address or a name, and a copy with
        // nothing to show for it is a copy nobody trusts: the screen says so,
        // every time, on every version of the system. (A newer Android draws its
        // own little clipboard chip as well, which is its business; a phone whose
        // maker turned that off is exactly why this does not depend on it.)
        val scope = rememberCoroutineScope()
        val copy: (String) -> Unit = { value ->
            scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(null, value))) }
            // The confirmation is about a tap that has already happened: shown long
            // enough to be seen, and then out of the way rather than sitting over the
            // screen for four seconds.
            scope.launch { snackbar.showSnackbar(message = copied, duration = SnackbarDuration.Indefinite) }
            scope.launch {
                delay(CopiedNoticeMs)
                snackbar.currentSnackbarData?.dismiss()
            }
        }
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            item { SectionHeader(l10n(MessageKeys.SETTINGS_LANGUAGE)) }
            item {
                ChoiceRow(l10n(MessageKeys.SETTINGS_LANGUAGE_SYSTEM), state.settings.language == Language.SYSTEM) {
                    vm.setLanguage(Language.SYSTEM)
                }
            }
            item { ChoiceRow(l10n(MessageKeys.LANGUAGE_ZH), state.settings.language == Language.ZH) { vm.setLanguage(Language.ZH) } }
            item { ChoiceRow(l10n(MessageKeys.LANGUAGE_EN), state.settings.language == Language.EN) { vm.setLanguage(Language.EN) } }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(l10n(MessageKeys.SETTINGS_APPEARANCE)) }
            item {
                ChoiceRow(l10n(MessageKeys.SETTINGS_APPEARANCE_SYSTEM), state.settings.appearance == Appearance.SYSTEM) {
                    vm.setAppearance(Appearance.SYSTEM)
                }
            }
            item {
                ChoiceRow(l10n(MessageKeys.SETTINGS_APPEARANCE_LIGHT), state.settings.appearance == Appearance.LIGHT) {
                    vm.setAppearance(Appearance.LIGHT)
                }
            }
            item {
                ChoiceRow(l10n(MessageKeys.SETTINGS_APPEARANCE_DARK), state.settings.appearance == Appearance.DARK) {
                    vm.setAppearance(Appearance.DARK)
                }
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(l10n(MessageKeys.SETTINGS_IDENTITIES)) }
            if (state.identities.isEmpty()) {
                item {
                    Text(
                        l10n(MessageKeys.SETTINGS_NO_IDENTITIES),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                }
            } else {
                items(state.identities.size) { index ->
                    val identity = state.identities[index]
                    var confirming by remember { mutableStateOf(false) }
                    // One connection is one block: the address and the name this
                    // device was admitted under, each a tap away from the
                    // clipboard, with the way out at the far end. Two blocks never
                    // touch — a stray tap must not be able to forget the wrong
                    // gateway.
                    ConnectionRow(
                        address = identity.origin,
                        name = identity.deviceName,
                        forget = l10n(MessageKeys.SETTINGS_FORGET),
                        onCopy = copy,
                        onForget = { confirming = true },
                    )
                    if (confirming) {
                        AlertDialog(
                            onDismissRequest = { confirming = false },
                            title = { Text(l10n(MessageKeys.SETTINGS_FORGET)) },
                            // Asking a question, not promising an outcome: another
                            // connection may reach the same machines, so "they will
                            // become unreachable" would be a claim this screen cannot
                            // make.
                            text = { Text(l10n(MessageKeys.SETTINGS_FORGET_CONFIRM)) },
                            confirmButton = {
                                TextButton(onClick = {
                                    confirming = false
                                    vm.forget(identity)
                                }) { Text(l10n(MessageKeys.ACTION_CONFIRM)) }
                            },
                            dismissButton = {
                                TextButton(onClick = { confirming = false }) {
                                    Text(l10n(MessageKeys.ACTION_CANCEL))
                                }
                            },
                        )
                    }
                }
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(l10n(MessageKeys.SETTINGS_ABOUT)) }
            item {
                // Three plain rows, the way a page about the build reads: what this
                // app is, what it speaks, and what this phone calls itself. Nothing
                // is boxed, because none of it is a list — and the version number is
                // the update check, without a button saying so.
                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    AboutRow(
                        label = l10n(MessageKeys.SETTINGS_VERSION),
                        value = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        onValue = { vm.checkUpdates() },
                    )
                    val message = when (val u = update) {
                        UpdateUiState.Idle -> null
                        UpdateUiState.Checking -> l10n(MessageKeys.SETTINGS_UPDATES_CHECKING)
                        UpdateUiState.UpToDate -> l10n(MessageKeys.SETTINGS_UPDATES_NONE)
                        is UpdateUiState.Available -> l10n(MessageKeys.SETTINGS_UPDATES_AVAILABLE, u.versionName, u.buildNumber) + " " + l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT)
                        UpdateUiState.ProtocolChanged -> l10n(MessageKeys.SETTINGS_UPDATES_PROTOCOL)
                        UpdateUiState.Unreachable -> l10n(MessageKeys.SETTINGS_UPDATES_FAILED)
                    }
                    if (message != null) {
                        Text(
                            message,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 4.dp),
                        )
                    }
                    AboutRow(
                        label = l10n(MessageKeys.SETTINGS_PROTOCOL_VERSION),
                        value = "${BuildConfig.PROTOCOL_VERSION}",
                    )
                    val model = android.os.Build.MODEL ?: ""
                    AboutRow(
                        label = l10n(MessageKeys.SETTINGS_DEVICE_NAME),
                        value = model,
                        onValue = { copy(model) },
                    )
                }
            }
        }
    }
}

/**
 * One line of "about this build": what it is on the left, what it is on the right,
 * and — where there is something a person can do with the value — the value is what
 * they tap. No button, because the value is the thing.
 */
@Composable
private fun AboutRow(label: String, value: String, onValue: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
        Text(
            value,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = if (onValue != null && value.isNotEmpty()) {
                Modifier.clickable { onValue() }
            } else {
                Modifier
            },
        )
    }
}

/** How long the "copied" line stays: a glance, not a paragraph. */
private const val CopiedNoticeMs = 1_200L

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/**
 * One connection: what it is, what it is called, and the way to forget it —
 * with the two things a person reads on the left, stacked and the same size,
 * and the one thing a person must not hit by accident at the far right. The
 * block is its own surface, so two connections never read as one list.
 */
@Composable
private fun ConnectionRow(
    address: String,
    name: String,
    forget: String,
    onCopy: (String) -> Unit,
    onForget: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                CopyableLine(address, MaterialTheme.colorScheme.onSurface, onCopy)
                CopyableLine(name, MaterialTheme.colorScheme.onSurfaceVariant, onCopy)
            }
            TextButton(onClick = onForget) {
                Text(
                    forget,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.error,
                    maxLines = 1,
                )
            }
        }
    }
}

/** A line of a connection that is also a thing to take away. */
@Composable
private fun CopyableLine(value: String, color: Color, onCopy: (String) -> Unit) {
    Text(
        value,
        style = MaterialTheme.typography.bodyLarge,
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCopy(value) }
            .padding(vertical = 2.dp),
    )
}

@Composable
private fun ChoiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 8.dp))
    }
}
