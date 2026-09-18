package com.remoteeverything.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.AppViewModel
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.UpdateUiState
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.store.Appearance
import com.remoteeverything.core.store.Language

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(vm: AppViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val update by vm.updateState.collectAsStateWithLifecycle()

    Scaffold(
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
                    val nodeCount = state.nodes.count { node -> node.paths.any { it.origin == identity.origin } }
                    var confirming by remember { mutableStateOf(false) }
                    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                        Text(identity.origin, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            identity.deviceName,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            "${l10n(MessageKeys.SETTINGS_CERTIFICATE_FINGERPRINT)}: ${identity.certFingerprint}",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            l10n(MessageKeys.SETTINGS_FORGET),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier
                                .padding(top = 8.dp)
                                .clickable { confirming = true },
                        )
                    }
                    if (confirming) {
                        AlertDialog(
                            onDismissRequest = { confirming = false },
                            title = { Text(l10n(MessageKeys.SETTINGS_FORGET)) },
                            text = { Text(l10n(MessageKeys.SETTINGS_FORGET_CONFIRM, nodeCount)) },
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
            item { SectionHeader(l10n(MessageKeys.SETTINGS_UPDATES)) }
            item {
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Text(
                        l10n(MessageKeys.SETTINGS_UPDATES_CURRENT, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    val message = when (val u = update) {
                        UpdateUiState.Idle -> null
                        UpdateUiState.Checking -> l10n(MessageKeys.SETTINGS_UPDATES_CHECKING)
                        UpdateUiState.UpToDate -> l10n(MessageKeys.SETTINGS_UPDATES_NONE)
                        is UpdateUiState.Available -> l10n(MessageKeys.SETTINGS_UPDATES_AVAILABLE, u.versionName, u.buildNumber) + " " + l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT)
                        UpdateUiState.ProtocolChanged -> l10n(MessageKeys.SETTINGS_UPDATES_PROTOCOL)
                        UpdateUiState.Unreachable -> l10n(MessageKeys.ERROR_NETWORK)
                    }
                    if (message != null) {
                        Text(
                            message,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                    Text(
                        l10n(MessageKeys.SETTINGS_UPDATES_CHECK),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .padding(top = 8.dp)
                            .clickable { vm.checkUpdates() },
                    )
                }
            }

            item { HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp)) }
            item { SectionHeader(l10n(MessageKeys.SETTINGS_ABOUT)) }
            item {
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Text(
                        l10n(MessageKeys.SETTINGS_PROTOCOL_VERSION, BuildConfig.PROTOCOL_VERSION),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Text(
                        "${l10n(MessageKeys.SETTINGS_DEVICE_NAME)}: ${android.os.Build.MODEL}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
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
