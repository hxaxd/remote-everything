package com.remoteeverything.app.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.remoteeverything.app.AppViewModel
import com.remoteeverything.app.PairingUiState
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.MessageKeys

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairScreen(vm: AppViewModel, onBack: () -> Unit) {
    var input by rememberSaveable { mutableStateOf("") }
    var deviceName by rememberSaveable { mutableStateOf(android.os.Build.MODEL ?: "") }
    val state by vm.state.collectAsStateWithLifecycle()
    val parsed = remember(input) { if (input.isBlank()) null else vm.parseInvitation(input) }
    val scanLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { input = it }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(l10n(MessageKeys.PAIR_TITLE)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = l10n(MessageKeys.ACTION_BACK),
                        )
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            scanLauncher.launch(
                                ScanOptions()
                                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                    .setBeepEnabled(false)
                                    .setOrientationLocked(false),
                            )
                        },
                    ) { Text(l10n(MessageKeys.PAIR_SCAN)) }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
        ) {
            when (val pairing = state.pairing) {
                is PairingUiState.Working -> Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(16.dp))
                    Text(l10n(MessageKeys.PAIR_WORKING))
                    Text(pairing.nodeName, style = MaterialTheme.typography.labelMedium)
                }

                is PairingUiState.Pending -> Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(l10n(MessageKeys.NODE_PENDING), style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Text(pairing.nodeName, style = MaterialTheme.typography.bodyLarge)
                    Spacer(Modifier.height(24.dp))
                    Button(onClick = { vm.resumePendingPairing() }) { Text(l10n(MessageKeys.ACTION_RETRY)) }
                    TextButton(onClick = onBack) { Text(l10n(MessageKeys.ACTION_BACK)) }
                }

                else -> {
                    OutlinedTextField(
                        value = input,
                        onValueChange = {
                            input = it
                            vm.resetPairing()
                        },
                        label = { Text(l10n(MessageKeys.PAIR_INPUT_HINT)) },
                        isError = input.isNotBlank() && parsed == null,
                        supportingText = {
                            if (input.isNotBlank() && parsed == null) {
                                Text(l10n(MessageKeys.PAIR_BAD_INVITATION))
                            }
                        },
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (pairing is PairingUiState.Failed) {
                        Spacer(Modifier.height(12.dp))
                        Text(
                            l10n(pairingFailureKey(pairing.code)),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    if (parsed != null) {
                        Spacer(Modifier.height(16.dp))
                        Card(modifier = Modifier.fillMaxWidth()) {
                            Column(modifier = Modifier.padding(16.dp)) {
                                Text(
                                    l10n(MessageKeys.PAIR_CONFIRM_BODY, parsed.origin, parsed.nodeName),
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                                Spacer(Modifier.height(12.dp))
                                OutlinedTextField(
                                    value = deviceName,
                                    onValueChange = { deviceName = it },
                                    label = { Text(l10n(MessageKeys.PAIR_DEVICE_NAME)) },
                                    singleLine = true,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                                Spacer(Modifier.height(16.dp))
                                Row {
                                    Button(
                                        onClick = { vm.pair(parsed, deviceName) },
                                        enabled = deviceName.isNotBlank(),
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Text(l10n(MessageKeys.PAIR_ACTION_JOIN))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * What a refusal means to the person holding the phone: the contract's name for
 * it, which is the one the fixtures pin. A failure below the protocol (nothing
 * answered at all) is the network's name.
 */
private fun pairingFailureKey(code: ErrorCode?): String =
    if (code == null) MessageKeys.ERROR_NETWORK else MessageKeys.forError(code)
