import Foundation

/// The names of everything a client says. These names — not sentences, and not
/// platform resources — are what the three clients agree on: each renders them
/// in its own way, in its own languages, and `clients/behavior/fixtures` asserts
/// that a given wire answer leads every client to the same name. A new refusal
/// code, a new state, a new sentence: one name here, three renderings, or the
/// behaviour test fails.
///
/// The names and the three mappings are the same in every client, spelled the
/// same way (Kotlin `camelCase`, Swift `camelCase`, ArkTS `camelCase`).
enum MessageKeys {

    // Node states
    static let NODE_LAN = "node.lan"
    static let NODE_TUNNEL = "node.tunnel"
    static let NODE_OFFLINE = "node.offline"
    static let NODE_PENDING = "node.pending"
    static let NODE_UNKNOWN = "node.unknown"

    // Application states
    static let APP_READY = "app.ready"
    static let APP_STARTING = "app.starting"
    static let APP_STOPPING = "app.stopping"
    static let APP_STOPPED = "app.stopped"

    // Pairing
    static let PAIR_DENIED = "pair.denied"
    static let PAIR_EXPIRED = "pair.expired"
    static let PAIR_BAD_INVITATION = "pair.bad_invitation"
    static let PAIR_NETWORK = "pair.network"
    static let PAIR_GATEWAY_TROUBLE = "pair.gateway_trouble"

    // Refusals
    static let ERROR_NODE_GONE = "error.node_gone"
    static let ERROR_BUSY = "error.busy"
    static let ERROR_APP_GONE = "error.app_gone"
    static let ERROR_STOP_FAILED = "error.stop_failed"
    static let ERROR_NOT_FOUND = "error.not_found"
    static let ERROR_CLIENT = "error.client"
    static let ERROR_NETWORK = "error.network"
    static let ERROR_CONTROL_FAILED = "error.control_failed"
    static let ERROR_CREDENTIAL_LOST = "error.credential_lost"
    static let ERROR_NODE_GONE_BODY = "error.node_gone_body"

    // What a device is
    static let DEVICE_CATEGORY_DEFAULT = "device.category_default"
    static let DEVICE_CATEGORY_PHONE = "device.category_phone"
    static let DEVICE_CATEGORY_TABLET = "device.category_tablet"

    // Screens
    static let APP_NAME = "app.name"
    static let APP_OPEN_FAILED = "app.open_failed"
    static let APPS_EMPTY_TITLE = "apps.empty_title"
    static let APPS_EMPTY_BODY = "apps.empty_body"
    static let NODES_TITLE = "nodes.title"
    static let NODES_SELECT_HINT = "nodes.select_hint"
    static let EMPTY_TITLE = "empty.title"
    static let EMPTY_BODY = "empty.body"
    static let ACTION_ADD_NODE = "action.add_node"
    static let ACTION_START = "action.start"
    static let ACTION_STOP = "action.stop"
    static let ACTION_RETRY = "action.retry"
    static let ACTION_BACK = "action.back"
    static let ACTION_BACK_TO_NODES = "action.back_to_nodes"
    static let ACTION_CANCEL = "action.cancel"
    static let ACTION_CONFIRM = "action.confirm"
    static let ACTION_DONE = "action.done"
    static let PAIR_TITLE = "pair.title"
    static let PAIR_INPUT_HINT = "pair.input_hint"
    static let PAIR_SCAN = "pair.scan"
    static let PAIR_SCAN_DENIED = "pair.scan_denied"
    static let PAIR_SCAN_BODY = "pair.scan_body"
    static let PAIR_SCAN_FAILED = "pair.scan_failed"
    static let PAIR_CONFIRM_BODY = "pair.confirm_body"
    static let PAIR_DEVICE_NAME = "pair.device_name"
    static let PAIR_DEVICE_NAME_HINT = "pair.device_name_hint"
    static let PAIR_DEVICE_NAME_REQUIRED = "pair.device_name_required"
    static let PAIR_GATEWAY_LABEL = "pair.gateway_label"
    static let PAIR_NODE_LABEL = "pair.node_label"
    static let PAIR_ACTION_JOIN = "pair.action_join"
    static let PAIR_WORKING = "pair.working"
    static let PAIR_WAITING_APPROVAL = "pair.waiting_approval"
    static let NODE_OFFLINE_TITLE = "node.offline_title"
    static let NODE_OFFLINE_BODY = "node.offline_body"
    static let WEB_LOAD_FAILED = "web.load_failed"
    static let WEB_LOADING = "web.loading"
    static let LANGUAGE_ZH = "language.zh"
    static let LANGUAGE_EN = "language.en"
    static let IDENTITY_UNAUTHORIZED = "identity.unauthorized"
    static let IDENTITY_NEEDS_PAIRING = "identity.needs_pairing"
    static let IDENTITY_NEEDS_PAIRING_BODY = "identity.needs_pairing_body"
    static let IDENTITY_NEEDS_PAIRING_TITLE = "identity.needs_pairing_title"
    static let SETTINGS_TITLE = "settings.title"
    static let SETTINGS_LANGUAGE = "settings.language"
    static let SETTINGS_LANGUAGE_SYSTEM = "settings.language_system"
    static let SETTINGS_APPEARANCE = "settings.appearance"
    static let SETTINGS_APPEARANCE_SYSTEM = "settings.appearance_system"
    static let SETTINGS_APPEARANCE_LIGHT = "settings.appearance_light"
    static let SETTINGS_APPEARANCE_DARK = "settings.appearance_dark"
    static let SETTINGS_IDENTITIES = "settings.identities"
    static let SETTINGS_NO_IDENTITIES = "settings.no_identities"
    static let SETTINGS_NODES_COUNT = "settings.nodes_count"
    static let SETTINGS_CERTIFICATE_FINGERPRINT = "settings.certificate_fingerprint"
    static let SETTINGS_FORGET = "settings.forget"
    static let SETTINGS_FORGET_CONFIRM = "settings.forget_confirm"
    static let SETTINGS_UPDATES = "settings.updates"
    static let SETTINGS_UPDATES_CHECK = "settings.updates_check"
    static let SETTINGS_UPDATES_CHECKING = "settings.updates_checking"
    static let SETTINGS_UPDATES_CURRENT = "settings.updates_current"
    static let SETTINGS_UPDATES_NONE = "settings.updates_none"
    static let SETTINGS_UPDATES_AVAILABLE = "settings.updates_available"
    static let SETTINGS_UPDATES_PROTOCOL = "settings.updates_protocol"
    static let SETTINGS_UPDATES_STORE_HINT = "settings.updates_store_hint"
    static let SETTINGS_UPDATES_FAILED = "settings.updates_failed"
    static let SETTINGS_ABOUT = "settings.about"
    static let SETTINGS_VERSION = "settings.version"
    static let SETTINGS_PROTOCOL_VERSION = "settings.protocol_version"
    static let SETTINGS_DEVICE_NAME = "settings.device_name"

    /// What a refusal code is called, wherever it arrived from.
    static func forError(_ code: ErrorCode) -> String {
        switch code {
        case .unauthorized, .nodeNotFound, .nodeRequired:
            return ERROR_NODE_GONE
        case .approvalPending:
            return NODE_PENDING
        case .computerOffline:
            return NODE_OFFLINE
        case .invitationDenied:
            return PAIR_DENIED
        case .invitationExpired:
            return PAIR_EXPIRED
        case .rateLimited, .serverBusy:
            return ERROR_BUSY
        case .appNotFound:
            return ERROR_APP_GONE
        case .pairingFailed, .activationFailed, .internalError:
            return PAIR_GATEWAY_TROUBLE
        case .invalidDeviceName, .invalidCredentialPassword, .invalidBody, .invalidJson:
            return ERROR_CLIENT
        case .notFound, .forbidden:
            return ERROR_NOT_FOUND
        }
    }

    /// What a node's reachability is called, wherever it is shown.
    static func forNodeStatus(_ status: NodeStatus) -> String {
        switch status {
        case .onlineLan: return NODE_LAN
        case .onlineTunnel: return NODE_TUNNEL
        case .offline: return NODE_OFFLINE
        case .pendingApproval: return NODE_PENDING
        case .unknown: return NODE_UNKNOWN
        }
    }

    /// What an application's state is called, wherever it is shown.
    static func forAppState(_ state: AppState) -> String {
        switch state {
        case .ready: return APP_READY
        case .starting: return APP_STARTING
        case .stopping: return APP_STOPPING
        case .stopped: return APP_STOPPED
        }
    }
}
