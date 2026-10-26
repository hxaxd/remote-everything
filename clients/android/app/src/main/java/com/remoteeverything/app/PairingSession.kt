package com.remoteeverything.app

import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.pairing.PairingService
import com.remoteeverything.core.pairing.StagedSetup
import com.remoteeverything.core.setup.SetupUri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Durable approvals are independent of the pairing form currently being edited. */
class PairingSession(
    private val scope: CoroutineScope,
    private val pairingService: PairingService,
    private val onNodesChanged: () -> Unit,
) {
    private val _pairing = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val pairing: StateFlow<PairingUiState> = _pairing.asStateFlow()
    private val _pending = MutableStateFlow<List<StagedSetup>>(emptyList())
    val pending: StateFlow<List<StagedSetup>> = _pending.asStateFlow()
    private var activeOrigin: String? = null
    private var approvalJob: Job? = null
    private var pairJob: Job? = null
    private var pairRun = 0L

    init { resumePendingPairing() }

    fun parseInvitation(text: String): SetupUri.Invitation? =
        try { SetupUri.parse(text) } catch (e: Exception) { null }

    private fun refreshPending() { _pending.value = pairingService.pendingSetups() }

    fun pair(invitation: SetupUri.Invitation, deviceName: String) {
        if (_pairing.value is PairingUiState.Working) return
        activeOrigin = invitation.origin
        val run = ++pairRun
        _pairing.value = PairingUiState.Working(invitation.nodeName)
        pairJob = scope.launch {
            val outcome = pairingService.run(invitation, deviceName.trim())
            refreshPending()
            if (outcome is PairingService.Outcome.Activated || outcome is PairingService.Outcome.ApprovalPending) onNodesChanged()
            if (_pending.value.isNotEmpty()) startApprovalPolling()
            if (run != pairRun || activeOrigin != invitation.origin) return@launch
            _pairing.value = when (outcome) {
                is PairingService.Outcome.Activated -> {
                    PairingUiState.Success(invitation.nodeName)
                }
                is PairingService.Outcome.ApprovalPending -> {
                    PairingUiState.Pending(outcome.nodeName)
                }
                is PairingService.Outcome.Failed -> PairingUiState.Failed(outcome.code, outcome.key)
            }
            if (_pending.value.isNotEmpty()) startApprovalPolling()
        }
    }

    fun cancelPairing() {
        pairRun++
        pairJob?.cancel()
        pairJob = null
        activeOrigin = null
        _pairing.value = PairingUiState.Idle
        refreshPending()
        if (_pending.value.isNotEmpty()) startApprovalPolling()
    }

    private suspend fun resumeAll(origin: String? = null) {
        for (staged in pairingService.pendingSetups().filter { origin == null || it.origin == origin }) {
            val outcome = pairingService.resume(staged.origin) ?: continue
            if (outcome is PairingService.Outcome.Activated) onNodesChanged()
            if (activeOrigin == staged.origin && _pairing.value !is PairingUiState.Working) {
                _pairing.value = when (outcome) {
                    is PairingService.Outcome.Activated -> PairingUiState.Success(staged.nodeName)
                    is PairingService.Outcome.ApprovalPending -> PairingUiState.Pending(staged.nodeName)
                    is PairingService.Outcome.Failed -> PairingUiState.Failed(outcome.code, outcome.key)
                }
            }
        }
        refreshPending()
    }

    fun startApprovalPolling() {
        if (approvalJob?.isActive == true) return
        approvalJob = scope.launch {
            val deadline = System.currentTimeMillis() + Cadence.approvalPollTimeoutMs
            while (System.currentTimeMillis() < deadline) {
                refreshPending()
                if (_pending.value.isEmpty()) return@launch
                delay(Cadence.approvalPollMs)
                resumeAll()
            }
        }
    }

    fun stopApprovalPolling() { approvalJob?.cancel(); approvalJob = null }

    fun forget(origin: String): Boolean {
        val removed = pairingService.discardStaged(origin)
        if (activeOrigin == origin) {
            pairRun++
            pairJob?.cancel()
            activeOrigin = null
            _pairing.value = PairingUiState.Idle
        }
        refreshPending()
        if (_pending.value.isEmpty()) stopApprovalPolling() else startApprovalPolling()
        return removed
    }

    fun resetPairing() {
        if (_pairing.value !is PairingUiState.Working) {
            activeOrigin = null
            _pairing.value = PairingUiState.Idle
        }
    }

    fun resumePendingPairing(origin: String? = null) {
        if (origin != null) activeOrigin = origin
        scope.launch {
            resumeAll(origin)
            if (_pending.value.isNotEmpty()) startApprovalPolling()
        }
    }
}
