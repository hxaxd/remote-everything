package com.remoteeverything.core.model

import kotlinx.serialization.Serializable

/**
 * One pairing result for one gateway origin: the device certificate plus what
 * the client remembers about that gateway. The wire counterpart is the pairing
 * response; the certificate itself lives in platform secure storage and is
 * only ever referenced here.
 */
@Serializable
data class Identity(
    val origin: String,
    val deviceName: String,
    val certFingerprint: String,
    val credentialRef: String,
    val serverPin: ServerPin? = null,
    val createdAtEpochMs: Long,
)

@Serializable
data class ServerPin(
    val certFingerprint: String,
    val publicKeyPin: String,
)

/** Merged view of one machine: the same node id seen through one or more gateways. */
data class Node(
    val id: String,
    val name: String,
    val paths: List<Path>,
)

data class Path(
    val origin: String,
    val identityRef: String = "",
    val reachable: Boolean? = null,
    val latencyMs: Long? = null,
    // Whether this address is on a private network. It is the *preference*: a path
    // that does not leave the local network is the one to take.
    val isPrivate: Boolean,
    val lastCheckedAt: Long? = null,
    // What the link is *called*, which is not the same question: a gateway may
    // declare that it carries this node over its own tunnel even though the phone
    // reaches the gateway at home, and a person reading "本地" while their traffic
    // crosses the internet is being told the wrong thing (NodesFixture, LinkKind).
    val link: LinkKind = if (isPrivate) LinkKind.LOCAL else LinkKind.TUNNEL,
)

/** The two words a link is shown in: a local one, or one over a tunnel. */
enum class LinkKind { LOCAL, TUNNEL }

enum class NodeStatus { UNKNOWN, ONLINE_LAN, ONLINE_TUNNEL, OFFLINE, PENDING_APPROVAL }

enum class AppState { READY, STARTING, STOPPING, STOPPED }

data class AppInfo(
    val id: String,
    val name: String,
    val description: String,
    val icon: String,
    val accent: String,
    val launchFragment: String,
    val enabled: Boolean,
    val running: Boolean,
    val code: AppState,
)

/** Every refusal code in contracts/errors.schema.json — all nineteen, none dropped. */
@Serializable
enum class ErrorCode {
    @kotlinx.serialization.SerialName("node_required") NODE_REQUIRED,
    @kotlinx.serialization.SerialName("unauthorized") UNAUTHORIZED,
    @kotlinx.serialization.SerialName("invitation_denied") INVITATION_DENIED,
    @kotlinx.serialization.SerialName("invitation_expired") INVITATION_EXPIRED,
    @kotlinx.serialization.SerialName("approval_pending") APPROVAL_PENDING,
    @kotlinx.serialization.SerialName("node_not_found") NODE_NOT_FOUND,
    @kotlinx.serialization.SerialName("app_not_found") APP_NOT_FOUND,
    @kotlinx.serialization.SerialName("not_found") NOT_FOUND,
    @kotlinx.serialization.SerialName("forbidden") FORBIDDEN,
    @kotlinx.serialization.SerialName("computer_offline") COMPUTER_OFFLINE,
    @kotlinx.serialization.SerialName("activation_failed") ACTIVATION_FAILED,
    @kotlinx.serialization.SerialName("invalid_device_name") INVALID_DEVICE_NAME,
    @kotlinx.serialization.SerialName("invalid_credential_password") INVALID_CREDENTIAL_PASSWORD,
    @kotlinx.serialization.SerialName("invalid_body") INVALID_BODY,
    @kotlinx.serialization.SerialName("invalid_json") INVALID_JSON,
    @kotlinx.serialization.SerialName("rate_limited") RATE_LIMITED,
    @kotlinx.serialization.SerialName("server_busy") SERVER_BUSY,
    @kotlinx.serialization.SerialName("pairing_failed") PAIRING_FAILED,
    @kotlinx.serialization.SerialName("internal_error") INTERNAL_ERROR,
}

/** A refusal from the wire: the code drives presentation, never prose. */
class ClientError(val code: ErrorCode, val httpStatus: Int? = null) : Exception("refused: $code")

/** A failure below the protocol: DNS, TLS, timeout — no code travels here. */
class NetworkError(cause: Throwable) : Exception("network failure", cause)
