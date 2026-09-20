package com.remoteeverything.app.ui

import com.remoteeverything.app.i18n.l10n
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScaffoldDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remoteeverything.app.AppModel
import com.remoteeverything.app.PairingUiState
import com.remoteeverything.app.R
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.MessageKeys
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairScreen(vm: AppModel, onBack: () -> Unit, embedded: Boolean = false) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    var input by rememberSaveable { mutableStateOf(vm.pendingInvitation.value ?: "") }
    var deviceName by rememberSaveable { mutableStateOf(android.os.Build.MODEL ?: "") }
    val state by vm.state.collectAsStateWithLifecycle()
    val parsed = remember(input) { if (input.isBlank()) null else vm.parseInvitation(input) }

    LaunchedEffect(Unit) {
        val pending = vm.pendingInvitation.value
        if (!pending.isNullOrBlank()) {
            input = pending
            vm.consumeInvitation()
        }
    }

    // P0-1: Finish pairing immediately upon success and navigate back
    LaunchedEffect(state.pairing) {
        if (state.pairing is PairingUiState.Success) {
            input = ""
            vm.resetPairing()
            onBack()
        }
    }

    // The camera screen is this app's own ([QrScanActivity]) rather than the
    // scanning library's stock activity: it stands up, it is drawn in this app's
    // colours, and it refuses a code that is not an invitation instead of handing
    // it to the field as a puzzle.
    val scanLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val code = result.data?.getStringExtra(QrScanActivity.ExtraCode)
        if (result.resultCode == android.app.Activity.RESULT_OK && !code.isNullOrBlank()) {
            input = code
            vm.resetPairing()
        }
    }
    val startScan = { scanLauncher.launch(QrScanActivity.intent(context)) }

    // Read while composing: the refusal is shown from a callback, and a string read
    // off the context there is one a language change would never recompose.
    val scanDenied = l10n(MessageKeys.PAIR_SCAN_DENIED)
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            startScan()
        } else {
            scope.launch {
                snackbarHostState.showSnackbar(scanDenied)
            }
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        // Beside the list, the surrounding layout has taken the system insets
        // already: taking them here too would double the bars above and below.
        contentWindowInsets = if (embedded) WindowInsets(0, 0, 0, 0) else ScaffoldDefaults.contentWindowInsets,
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
                windowInsets = if (embedded) WindowInsets(0, 0, 0, 0) else TopAppBarDefaults.windowInsets,
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
                    Spacer(Modifier.height(24.dp))
                    OutlinedButton(onClick = { vm.cancelPairing() }) {
                        Text(l10n(MessageKeys.ACTION_CANCEL))
                    }
                }

                is PairingUiState.Pending -> Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(16.dp))
                    Text(
                        l10n(MessageKeys.PAIR_WAITING_APPROVAL),
                        style = MaterialTheme.typography.titleMedium,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        pairing.nodeName,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(24.dp))
                    Button(onClick = { vm.resumePendingPairing() }) {
                        Text(l10n(MessageKeys.ACTION_RETRY))
                    }
                    Spacer(Modifier.height(8.dp))
                    TextButton(onClick = onBack) {
                        Text(l10n(MessageKeys.ACTION_BACK))
                    }
                }

                else -> {
                    // A pasted invitation is a long line, and this screen is not
                    // allowed to grow with it: the field stops at a few lines and
                    // scrolls inside itself, and the whole column scrolls, so the
                    // button that finishes the job is always on screen.
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState()),
                    ) {
                    // P1-1: Prominent scan button
                    Button(
                        onClick = {
                            val hasCam = ContextCompat.checkSelfPermission(
                                context,
                                Manifest.permission.CAMERA,
                            ) == PackageManager.PERMISSION_GRANTED
                            if (hasCam) startScan() else permissionLauncher.launch(Manifest.permission.CAMERA)
                        },
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                    ) {
                        Text(l10n(MessageKeys.PAIR_SCAN))
                    }

                    Spacer(Modifier.height(16.dp))

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
                        // An invitation URI is three hundred-odd characters: the
                        // field shows a few lines of it and scrolls, rather than
                        // pushing everything below it off the screen.
                        maxLines = 3,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    if (pairing is PairingUiState.Failed) {
                        Spacer(Modifier.height(12.dp))
                        Text(
                            l10n(pairing.key ?: pairingFailureKey(pairing.code)),
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
                                    supportingText = {
                                        if (deviceName.isBlank()) {
                                            Text(l10n(MessageKeys.PAIR_DEVICE_NAME_REQUIRED))
                                        } else {
                                            Text(l10n(MessageKeys.PAIR_DEVICE_NAME_HINT))
                                        }
                                    },
                                    isError = deviceName.isBlank(),
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
                                Spacer(Modifier.height(24.dp))
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
