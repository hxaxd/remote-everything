package com.remoteeverything.core.model

/**
 * The names of everything a client says. These names — not sentences, and not
 * platform resources — are what the three clients agree on: each renders them
 * in its own way, in its own languages, and `clients/behavior/fixtures` asserts
 * that a given wire answer leads every client to the same name. The set itself
 * is pinned to `message-keys.json`: a new sentence appears here and there
 * together, or the behaviour test fails. A platform resource carries the same
 * name with dots replaced by underscores (`pair.scan` → `pair_scan`).
 */
object MessageKeys {

    // Actions
    const val ACTION_ADD_NODE = "action.add_node"
    const val ACTION_BACK = "action.back"
    const val ACTION_BACK_TO_NODES = "action.back_to_nodes"
    const val ACTION_CANCEL = "action.cancel"
    const val ACTION_CONFIRM = "action.confirm"
    const val ACTION_COPIED = "action.copied"
    const val ACTION_DONE = "action.done"
    const val ACTION_RETRY = "action.retry"
    const val ACTION_START = "action.start"
    const val ACTION_STOP = "action.stop"

    // The product
    const val APP_NAME = "app.name"
    const val APP_OPEN_FAILED = "app.open_failed"
    const val APP_READY = "app.ready"
    const val APP_STARTING = "app.starting"
    const val APP_STOPPED = "app.stopped"
    const val APP_STOPPING = "app.stopping"
    const val APPS_EMPTY_BODY = "apps.empty_body"
    const val APPS_EMPTY_TITLE = "apps.empty_title"

    // What a device is
    const val DEVICE_CATEGORY_DEFAULT = "device.category_default"
    const val DEVICE_CATEGORY_PHONE = "device.category_phone"
    const val DEVICE_CATEGORY_TABLET = "device.category_tablet"

    // The screen with nothing in it yet
    const val EMPTY_BODY = "empty.body"
    const val EMPTY_TITLE = "empty.title"

    // Refusals and failures
    const val ERROR_APP_GONE = "error.app_gone"
    const val ERROR_BUSY = "error.busy"
    const val ERROR_CLIENT = "error.client"
    const val ERROR_CONTROL_FAILED = "error.control_failed"
    const val ERROR_CREDENTIAL_LOST = "error.credential_lost"
    const val ERROR_NETWORK = "error.network"
    const val ERROR_NODE_GONE = "error.node_gone"
    const val ERROR_NODE_GONE_BODY = "error.node_gone_body"
    const val ERROR_NOT_FOUND = "error.not_found"
    const val ERROR_STOP_FAILED = "error.stop_failed"

    // Pairing interrupted
    const val IDENTITY_NEEDS_PAIRING = "identity.needs_pairing"
    const val IDENTITY_NEEDS_PAIRING_BODY = "identity.needs_pairing_body"
    const val IDENTITY_NEEDS_PAIRING_TITLE = "identity.needs_pairing_title"
    const val IDENTITY_UNAUTHORIZED = "identity.unauthorized"

    // Language names
    const val LANGUAGE_EN = "language.en"
    const val LANGUAGE_ZH = "language.zh"

    // Node states and the node list
    const val NODE_CURRENT_LAN = "node.current_lan"
    const val NODE_CURRENT_TUNNEL = "node.current_tunnel"
    const val NODE_LAN = "node.lan"
    const val NODE_OFFLINE = "node.offline"
    const val NODE_OFFLINE_BODY = "node.offline_body"
    const val NODE_OFFLINE_TITLE = "node.offline_title"
    const val NODE_PENDING = "node.pending"
    const val NODE_TUNNEL = "node.tunnel"
    const val NODE_UNKNOWN = "node.unknown"
    const val NODES_SELECT_HINT = "nodes.select_hint"
    const val NODES_TITLE = "nodes.title"

    // Pairing
    const val PAIR_ACTION_JOIN = "pair.action_join"
    const val PAIR_BAD_INVITATION = "pair.bad_invitation"
    const val PAIR_CONFIRM_BODY = "pair.confirm_body"
    const val PAIR_DENIED = "pair.denied"
    const val PAIR_DEVICE_NAME = "pair.device_name"
    const val PAIR_DEVICE_NAME_HINT = "pair.device_name_hint"
    const val PAIR_DEVICE_NAME_REQUIRED = "pair.device_name_required"
    const val PAIR_EXPIRED = "pair.expired"
    const val PAIR_GATEWAY_LABEL = "pair.gateway_label"
    const val PAIR_GATEWAY_TROUBLE = "pair.gateway_trouble"
    const val PAIR_INPUT_HINT = "pair.input_hint"
    const val PAIR_NETWORK = "pair.network"
    const val PAIR_NODE_LABEL = "pair.node_label"
    const val PAIR_SCAN = "pair.scan"
    const val PAIR_SCAN_BODY = "pair.scan_body"
    const val PAIR_SCAN_DENIED = "pair.scan_denied"
    const val PAIR_SCAN_FAILED = "pair.scan_failed"
    const val PAIR_TITLE = "pair.title"
    const val PAIR_WAITING_APPROVAL = "pair.waiting_approval"
    const val PAIR_WORKING = "pair.working"

    // Settings
    const val SETTINGS_ABOUT = "settings.about"
    const val SETTINGS_APPEARANCE = "settings.appearance"
    const val SETTINGS_APPEARANCE_DARK = "settings.appearance_dark"
    const val SETTINGS_APPEARANCE_LIGHT = "settings.appearance_light"
    const val SETTINGS_APPEARANCE_SYSTEM = "settings.appearance_system"
    const val SETTINGS_CERTIFICATE_FINGERPRINT = "settings.certificate_fingerprint"
    const val SETTINGS_DEVICE_NAME = "settings.device_name"
    const val SETTINGS_FORGET = "settings.forget"
    const val SETTINGS_FORGET_CONFIRM = "settings.forget_confirm"
    const val SETTINGS_IDENTITIES = "settings.identities"
    const val SETTINGS_LANGUAGE = "settings.language"
    const val SETTINGS_LANGUAGE_SYSTEM = "settings.language_system"
    const val SETTINGS_NO_IDENTITIES = "settings.no_identities"
    const val SETTINGS_NODES_COUNT = "settings.nodes_count"
    const val SETTINGS_PROTOCOL_VERSION = "settings.protocol_version"
    const val SETTINGS_TITLE = "settings.title"
    const val SETTINGS_UPDATES = "settings.updates"
    const val SETTINGS_UPDATES_AVAILABLE = "settings.updates_available"
    const val SETTINGS_UPDATES_CHECK = "settings.updates_check"
    const val SETTINGS_UPDATES_CHECKING = "settings.updates_checking"
    const val SETTINGS_UPDATES_CURRENT = "settings.updates_current"
    const val SETTINGS_UPDATES_FAILED = "settings.updates_failed"
    const val SETTINGS_UPDATES_NONE = "settings.updates_none"
    const val SETTINGS_UPDATES_PROTOCOL = "settings.updates_protocol"
    const val SETTINGS_UPDATES_STORE_HINT = "settings.updates_store_hint"
    const val SETTINGS_VERSION = "settings.version"

    // The web view
    const val WEB_CHOOSE_FILE = "web.choose_file"
    const val WEB_DOWNLOAD_DONE = "web.download_done"
    const val WEB_DOWNLOAD_FAILED = "web.download_failed"
    const val WEB_DOWNLOAD_OPEN = "web.download_open"
    const val WEB_DOWNLOAD_SAVED = "web.download_saved"
    const val WEB_DOWNLOADS = "web.downloads"
    const val WEB_EXIT = "web.exit"
    const val WEB_LOAD_FAILED = "web.load_failed"
    const val WEB_LOADING = "web.loading"
    const val WEB_ORIENTATION = "web.orientation"
    const val WEB_ORIENTATION_LANDSCAPE = "web.orientation_landscape"
    const val WEB_ORIENTATION_PORTRAIT = "web.orientation_portrait"
    const val WEB_ORIENTATION_SYSTEM = "web.orientation_system"
    const val WEB_REFRESH = "web.refresh"
    const val WEB_USER_AGENT = "web.user_agent"
    const val WEB_USER_AGENT_DESKTOP = "web.user_agent_desktop"
    const val WEB_USER_AGENT_MOBILE = "web.user_agent_mobile"

    /** What a refusal code is called, wherever it arrived from. */
    fun forError(code: ErrorCode): String = when (code) {
        ErrorCode.UNAUTHORIZED, ErrorCode.NODE_NOT_FOUND, ErrorCode.NODE_REQUIRED -> ERROR_NODE_GONE
        ErrorCode.APPROVAL_PENDING -> NODE_PENDING
        ErrorCode.COMPUTER_OFFLINE -> NODE_OFFLINE
        ErrorCode.INVITATION_DENIED -> PAIR_DENIED
        ErrorCode.INVITATION_EXPIRED -> PAIR_EXPIRED
        ErrorCode.RATE_LIMITED, ErrorCode.SERVER_BUSY -> ERROR_BUSY
        ErrorCode.APP_NOT_FOUND -> ERROR_APP_GONE
        ErrorCode.PAIRING_FAILED, ErrorCode.ACTIVATION_FAILED, ErrorCode.INTERNAL_ERROR -> PAIR_GATEWAY_TROUBLE
        ErrorCode.INVALID_DEVICE_NAME, ErrorCode.INVALID_CREDENTIAL_PASSWORD,
        ErrorCode.INVALID_BODY, ErrorCode.INVALID_JSON,
        -> ERROR_CLIENT
        ErrorCode.NOT_FOUND, ErrorCode.FORBIDDEN -> ERROR_NOT_FOUND
    }

    /** What a node's reachability is called, wherever it is shown. */
    fun forNodeStatus(status: NodeStatus): String = when (status) {
        NodeStatus.ONLINE_LAN -> NODE_LAN
        NodeStatus.ONLINE_TUNNEL -> NODE_TUNNEL
        NodeStatus.OFFLINE -> NODE_OFFLINE
        NodeStatus.PENDING_APPROVAL -> NODE_PENDING
        NodeStatus.UNKNOWN -> NODE_UNKNOWN
    }

    /** What an application's state is called, wherever it is shown. */
    fun forAppState(state: AppState): String = when (state) {
        AppState.READY -> APP_READY
        AppState.STARTING -> APP_STARTING
        AppState.STOPPING -> APP_STOPPING
        AppState.STOPPED -> APP_STOPPED
    }
}
