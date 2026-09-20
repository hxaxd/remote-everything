package com.remoteeverything.core.api

import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.AppState
import com.remoteeverything.core.model.ErrorCode
import kotlinx.serialization.Serializable

/**
 * Wire bodies, mirroring clients/contracts/schemas one to one. Decoding is
 * strict on purpose: unknown keys fail, missing keys fail, unknown enum values
 * fail — the same rule the Go side enforces (see contracts README: an
 * implementation rejects a body it does not understand rather than tolerating
 * it).
 */

@Serializable
data class NodesResponse(
    val ok: Boolean,
    val nodes: List<NodeDto>,
)

@Serializable
data class NodeDto(
    val id: String,
    val name: String,
    /** How the answering gateway reaches it, when the operator or the gateway said. */
    val link: String? = null,
)

@Serializable
data class CatalogResponse(
    val ok: Boolean,
    val computer_connected: Boolean,
    val code: CatalogCode,
    val apps: List<AppDto>,
)

@Serializable
enum class CatalogCode {
    @kotlinx.serialization.SerialName("ready") READY,
    @kotlinx.serialization.SerialName("computer_offline") COMPUTER_OFFLINE,
}

@Serializable
data class AppDto(
    val id: String,
    val name: String,
    val description: String,
    val icon: String,
    val accent: String,
    val launch_fragment: String,
    val computer_connected: Boolean,
    val enabled: Boolean,
    val running: Boolean,
    val code: AppCode,
)

@Serializable
enum class AppCode {
    @kotlinx.serialization.SerialName("ready") READY,
    @kotlinx.serialization.SerialName("starting") STARTING,
    @kotlinx.serialization.SerialName("stopping") STOPPING,
    @kotlinx.serialization.SerialName("stopped") STOPPED,
}

@Serializable
data class PairingRequest(
    val device_name: String,
    val credential_password: String,
)

@Serializable
data class PairingResponse(
    val ok: Boolean,
    val device_name: String,
    val certificate_fingerprint: String,
    val credential_format: String,
    val credential_pkcs12: String,
    val pending_expires_at: String,
)

@Serializable
data class ControlResponse(
    val ok: Boolean,
    val action: ControlAction,
    val computer_connected: Boolean,
    val enabled: Boolean,
    val running: Boolean,
    val code: ControlCode,
    val app: AppDto? = null,
    val error_code: String? = null,
)

@Serializable
enum class ControlAction {
    @kotlinx.serialization.SerialName("status") STATUS,
    @kotlinx.serialization.SerialName("start") START,
    @kotlinx.serialization.SerialName("stop") STOP,
}

@Serializable
enum class ControlCode {
    @kotlinx.serialization.SerialName("ready") READY,
    @kotlinx.serialization.SerialName("starting") STARTING,
    @kotlinx.serialization.SerialName("stopping") STOPPING,
    @kotlinx.serialization.SerialName("stopped") STOPPED,
    @kotlinx.serialization.SerialName("computer_offline") COMPUTER_OFFLINE,
    @kotlinx.serialization.SerialName("app_not_found") APP_NOT_FOUND,
    @kotlinx.serialization.SerialName("state_update_failed") STATE_UPDATE_FAILED,
}

@Serializable
data class ErrorResponse(
    val ok: Boolean,
    val code: ErrorCode,
)

/** What a wire application is to the client that shows it. */
fun AppDto.toAppInfo(): AppInfo = AppInfo(
    id = id,
    name = name,
    description = description,
    icon = icon,
    accent = accent,
    launchFragment = launch_fragment,
    enabled = enabled,
    running = running,
    code = when (code) {
        AppCode.READY -> AppState.READY
        AppCode.STARTING -> AppState.STARTING
        AppCode.STOPPING -> AppState.STOPPING
        AppCode.STOPPED -> AppState.STOPPED
    },
)
