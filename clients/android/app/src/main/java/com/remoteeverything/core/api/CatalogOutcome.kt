package com.remoteeverything.core.api

import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode

/**
 * What one catalog answer means for the screen that shows it. The wire says
 * "this machine is off" as an answer, not a refusal, so the screen it leads to
 * is a state rather than an error; only a device that is no longer allowed, or a
 * gateway that cannot be read, are the other ways a node's screen can end up.
 */
sealed interface CatalogOutcome {
    data class Apps(val apps: List<AppInfo>) : CatalogOutcome
    data object Offline : CatalogOutcome
    data object Unauthorized : CatalogOutcome
    data object GatewayTrouble : CatalogOutcome

    companion object {
        fun forAnswer(answer: CatalogResponse): CatalogOutcome =
            if (!answer.computer_connected || answer.code == CatalogCode.COMPUTER_OFFLINE) {
                Offline
            } else {
                Apps(answer.apps.map { it.toAppInfo() })
            }

        fun forRefusal(error: ClientError): CatalogOutcome = when (error.code) {
            ErrorCode.UNAUTHORIZED, ErrorCode.NODE_NOT_FOUND, ErrorCode.NODE_REQUIRED -> Unauthorized
            ErrorCode.COMPUTER_OFFLINE -> Offline
            else -> GatewayTrouble
        }
    }
}
