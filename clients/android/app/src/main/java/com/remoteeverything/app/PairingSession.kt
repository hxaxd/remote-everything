package com.remoteeverything.app

import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.pairing.PairingService
import com.remoteeverything.core.setup.SetupUri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Manages the interactive two-round pairing flow, staged pairing state, and
 * background approval polling when a device is pending operator approval.
 */
class PairingSession(
    private val scope: CoroutineScope,
    private val pairingService: PairingService,
    private val onNodesChanged: () -> Unit,
) {
    private val _pairing = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val pairing: StateFlow<PairingUiState> = _pairing.asStateFlow()

    private var approvalJob: Job? = null

    init {
        scope.launch {
            // A pairing that was interrupted is finished before anything else: the
            // invitation behind it is spent, and this is the only way it is not wasted.
            val state = askAboutPendingDevice()
            if (state != null) {
                _pairing.value = state
                if (state is PairingUiState.Pending) {
                    startApprovalPolling()
                }
            }
        }
    }

    private var pairJob: Job? = null

    fun parseInvitation(text: String): SetupUri.Invitation? =
        try {
            SetupUri.parse(text)
        } catch (e: Exception) {
            null
        }

    fun pair(invitation: SetupUri.Invitation, deviceName: String) {
        if (_pairing.value is PairingUiState.Working) return
        _pairing.value = PairingUiState.Working(invitation.nodeName)
        pairJob = scope.launch {
            when (val outcome = pairingService.run(invitation, deviceName.trim())) {
                is PairingService.Outcome.Activated -> {
                    _pairing.value = PairingUiState.Success(invitation.nodeName)
                    onNodesChanged()
                }
                is PairingService.Outcome.ApprovalPending -> {
                    _pairing.value = PairingUiState.Pending(outcome.nodeName)
                    onNodesChanged()
                    startApprovalPolling()
                }
                is PairingService.Outcome.Failed -> _pairing.value = PairingUiState.Failed(outcome.code)
            }
        }
    }

    fun cancelPairing() {
        pairJob?.cancel()
        pairJob = null
        if (_pairing.value is PairingUiState.Working) {
            _pairing.value = PairingUiState.Idle
        }
    }

    /**
     * One question about a device that paired and is waiting for its operator. A
     * waiting device is asked about on its own every [Cadence.approvalPollMs] for
     * [Cadence.approvalPollTimeoutMs], because waiting for somebody to tap retry is
     * not the same product as being admitted a moment after they approve.
     */
    private suspend fun askAboutPendingDevice(): PairingUiState? =
        when (val outcome = pairingService.resume()) {
            null -> null
            is PairingService.Outcome.Activated -> {
                onNodesChanged()
                PairingUiState.Success(outcome.nodeName)
            }
            is PairingService.Outcome.ApprovalPending -> PairingUiState.Pending(outcome.nodeName)
            is PairingService.Outcome.Failed -> PairingUiState.Failed(outcome.code)
        }

    fun startApprovalPolling() {
        if (approvalJob?.isActive == true) return
        approvalJob = scope.launch {
            val deadline = System.currentTimeMillis() + Cadence.approvalPollTimeoutMs
            while (System.currentTimeMillis() < deadline) {
                delay(Cadence.approvalPollMs)
                when (val state = askAboutPendingDevice()) {
                    null -> return@launch
                    is PairingUiState.Pending -> _pairing.value = state
                    else -> {
                        _pairing.value = state
                        return@launch
                    }
                }
            }
        }
    }

    fun stopApprovalPolling() {
        approvalJob?.cancel()
        approvalJob = null
    }

    fun resetPairing() {
        if (_pairing.value !is PairingUiState.Working) {
            _pairing.value = PairingUiState.Idle
        }
    }

    /** A waiting device, asked about now rather than at the next poll. */
    fun resumePendingPairing() {
        scope.launch {
            val state = askAboutPendingDevice()
            if (state != null) {
                _pairing.value = state
                if (state !is PairingUiState.Pending) {
                    stopApprovalPolling()
                }
            }
        }
    }
}
