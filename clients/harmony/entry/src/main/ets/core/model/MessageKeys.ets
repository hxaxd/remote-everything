// The names of everything this client says, and the mappings that decide which name
// a wire answer gets.
//
// These names — not sentences, and not platform resources — are what the three
// clients agree on (clients/behavior/README.md). Each renders them in its own way, in
// its own languages, and clients/behavior/fixtures asserts that a given answer leads
// every client to the same name. The set itself is pinned to message-keys.json: a new
// sentence appears here and there together, or the behaviour test fails. A resource
// carries the same name with its dots written as underscores, because that is the one
// character a platform resource name may not carry.

import { AppState, NodeStatus } from './Models';
import { ErrorCode } from './Errors';

export class MessageKeys {
  // Actions
  static readonly ACTION_ADD_NODE: string = 'action.add_node';
  static readonly ACTION_BACK: string = 'action.back';
  static readonly ACTION_BACK_TO_NODES: string = 'action.back_to_nodes';
  static readonly ACTION_CANCEL: string = 'action.cancel';
  static readonly ACTION_CONFIRM: string = 'action.confirm';
  static readonly ACTION_DONE: string = 'action.done';
  static readonly ACTION_RETRY: string = 'action.retry';
  static readonly ACTION_START: string = 'action.start';
  static readonly ACTION_STOP: string = 'action.stop';

  // The product
  static readonly APP_NAME: string = 'app.name';
  static readonly APP_OPEN_FAILED: string = 'app.open_failed';
  static readonly APP_READY: string = 'app.ready';
  static readonly APP_STARTING: string = 'app.starting';
  static readonly APP_STOPPED: string = 'app.stopped';
  static readonly APP_STOPPING: string = 'app.stopping';
  static readonly APPS_EMPTY_BODY: string = 'apps.empty_body';
  static readonly APPS_EMPTY_TITLE: string = 'apps.empty_title';

  // What a device is
  static readonly DEVICE_CATEGORY_DEFAULT: string = 'device.category_default';
  static readonly DEVICE_CATEGORY_PHONE: string = 'device.category_phone';
  static readonly DEVICE_CATEGORY_TABLET: string = 'device.category_tablet';

  // The screen with nothing in it yet
  static readonly EMPTY_BODY: string = 'empty.body';
  static readonly EMPTY_TITLE: string = 'empty.title';

  // Refusals and failures
  static readonly ERROR_APP_GONE: string = 'error.app_gone';
  static readonly ERROR_BUSY: string = 'error.busy';
  static readonly ERROR_CLIENT: string = 'error.client';
  static readonly ERROR_CONTROL_FAILED: string = 'error.control_failed';
  static readonly ERROR_CREDENTIAL_LOST: string = 'error.credential_lost';
  static readonly ERROR_NETWORK: string = 'error.network';
  static readonly ERROR_NODE_GONE: string = 'error.node_gone';
  static readonly ERROR_NODE_GONE_BODY: string = 'error.node_gone_body';
  static readonly ERROR_NOT_FOUND: string = 'error.not_found';
  static readonly ERROR_STOP_FAILED: string = 'error.stop_failed';

  // Pairing interrupted
  static readonly IDENTITY_NEEDS_PAIRING: string = 'identity.needs_pairing';
  static readonly IDENTITY_NEEDS_PAIRING_BODY: string = 'identity.needs_pairing_body';
  static readonly IDENTITY_NEEDS_PAIRING_TITLE: string = 'identity.needs_pairing_title';
  static readonly IDENTITY_UNAUTHORIZED: string = 'identity.unauthorized';

  // Language names
  static readonly LANGUAGE_EN: string = 'language.en';
  static readonly LANGUAGE_ZH: string = 'language.zh';

  // Node states and the node list
  static readonly NODE_LAN: string = 'node.lan';
  static readonly NODE_OFFLINE: string = 'node.offline';
  static readonly NODE_OFFLINE_BODY: string = 'node.offline_body';
  static readonly NODE_OFFLINE_TITLE: string = 'node.offline_title';
  static readonly NODE_PENDING: string = 'node.pending';
  static readonly NODE_TUNNEL: string = 'node.tunnel';
  static readonly NODE_UNKNOWN: string = 'node.unknown';
  static readonly NODES_SELECT_HINT: string = 'nodes.select_hint';
  static readonly NODES_TITLE: string = 'nodes.title';

  // Pairing
  static readonly PAIR_ACTION_JOIN: string = 'pair.action_join';
  static readonly PAIR_BAD_INVITATION: string = 'pair.bad_invitation';
  static readonly PAIR_CONFIRM_BODY: string = 'pair.confirm_body';
  static readonly PAIR_DENIED: string = 'pair.denied';
  static readonly PAIR_DEVICE_NAME: string = 'pair.device_name';
  static readonly PAIR_DEVICE_NAME_HINT: string = 'pair.device_name_hint';
  static readonly PAIR_DEVICE_NAME_REQUIRED: string = 'pair.device_name_required';
  static readonly PAIR_EXPIRED: string = 'pair.expired';
  static readonly PAIR_GATEWAY_LABEL: string = 'pair.gateway_label';
  static readonly PAIR_GATEWAY_TROUBLE: string = 'pair.gateway_trouble';
  static readonly PAIR_INPUT_HINT: string = 'pair.input_hint';
  static readonly PAIR_NETWORK: string = 'pair.network';
  static readonly PAIR_NODE_LABEL: string = 'pair.node_label';
  static readonly PAIR_SCAN: string = 'pair.scan';
  static readonly PAIR_SCAN_BODY: string = 'pair.scan_body';
  static readonly PAIR_SCAN_DENIED: string = 'pair.scan_denied';
  static readonly PAIR_SCAN_FAILED: string = 'pair.scan_failed';
  static readonly PAIR_TITLE: string = 'pair.title';
  static readonly PAIR_WAITING_APPROVAL: string = 'pair.waiting_approval';
  static readonly PAIR_WORKING: string = 'pair.working';

  // Settings
  static readonly SETTINGS_ABOUT: string = 'settings.about';
  static readonly SETTINGS_APPEARANCE: string = 'settings.appearance';
  static readonly SETTINGS_APPEARANCE_DARK: string = 'settings.appearance_dark';
  static readonly SETTINGS_APPEARANCE_LIGHT: string = 'settings.appearance_light';
  static readonly SETTINGS_APPEARANCE_SYSTEM: string = 'settings.appearance_system';
  static readonly SETTINGS_CERTIFICATE_FINGERPRINT: string = 'settings.certificate_fingerprint';
  static readonly SETTINGS_DEVICE_NAME: string = 'settings.device_name';
  static readonly SETTINGS_FORGET: string = 'settings.forget';
  static readonly SETTINGS_FORGET_CONFIRM: string = 'settings.forget_confirm';
  static readonly SETTINGS_IDENTITIES: string = 'settings.identities';
  static readonly SETTINGS_LANGUAGE: string = 'settings.language';
  static readonly SETTINGS_LANGUAGE_SYSTEM: string = 'settings.language_system';
  static readonly SETTINGS_NO_IDENTITIES: string = 'settings.no_identities';
  static readonly SETTINGS_NODES_COUNT: string = 'settings.nodes_count';
  static readonly SETTINGS_PROTOCOL_VERSION: string = 'settings.protocol_version';
  static readonly SETTINGS_TITLE: string = 'settings.title';
  static readonly SETTINGS_UPDATES: string = 'settings.updates';
  static readonly SETTINGS_UPDATES_AVAILABLE: string = 'settings.updates_available';
  static readonly SETTINGS_UPDATES_CHECK: string = 'settings.updates_check';
  static readonly SETTINGS_UPDATES_CHECKING: string = 'settings.updates_checking';
  static readonly SETTINGS_UPDATES_CURRENT: string = 'settings.updates_current';
  static readonly SETTINGS_UPDATES_FAILED: string = 'settings.updates_failed';
  static readonly SETTINGS_UPDATES_NONE: string = 'settings.updates_none';
  static readonly SETTINGS_UPDATES_PROTOCOL: string = 'settings.updates_protocol';
  static readonly SETTINGS_UPDATES_STORE_HINT: string = 'settings.updates_store_hint';
  static readonly SETTINGS_VERSION: string = 'settings.version';

  // The web view
  static readonly WEB_LOAD_FAILED: string = 'web.load_failed';
  static readonly WEB_LOADING: string = 'web.loading';

  /** What a refusal code is called, wherever it arrived from. */
  static forError(code: ErrorCode): string {
    switch (code) {
      case ErrorCode.Unauthorized:
      case ErrorCode.NodeNotFound:
      case ErrorCode.NodeRequired:
        return MessageKeys.ERROR_NODE_GONE;
      case ErrorCode.ApprovalPending:
        return MessageKeys.NODE_PENDING;
      case ErrorCode.ComputerOffline:
        return MessageKeys.NODE_OFFLINE;
      case ErrorCode.InvitationDenied:
        return MessageKeys.PAIR_DENIED;
      case ErrorCode.InvitationExpired:
        return MessageKeys.PAIR_EXPIRED;
      case ErrorCode.RateLimited:
      case ErrorCode.ServerBusy:
        return MessageKeys.ERROR_BUSY;
      case ErrorCode.AppNotFound:
        return MessageKeys.ERROR_APP_GONE;
      case ErrorCode.PairingFailed:
      case ErrorCode.ActivationFailed:
      case ErrorCode.InternalError:
        return MessageKeys.PAIR_GATEWAY_TROUBLE;
      case ErrorCode.NotFound:
      case ErrorCode.Forbidden:
        return MessageKeys.ERROR_NOT_FOUND;
      default:
        return MessageKeys.ERROR_CLIENT;
    }
  }

  /** What a node's reachability is called, wherever it is shown. */
  static forNodeStatus(status: NodeStatus): string {
    switch (status) {
      case NodeStatus.OnlineLan:
        return MessageKeys.NODE_LAN;
      case NodeStatus.OnlineTunnel:
        return MessageKeys.NODE_TUNNEL;
      case NodeStatus.Offline:
        return MessageKeys.NODE_OFFLINE;
      case NodeStatus.PendingApproval:
        return MessageKeys.NODE_PENDING;
      default:
        return MessageKeys.NODE_UNKNOWN;
    }
  }

  /** What an application's state is called, wherever it is shown. */
  static forAppState(state: AppState): string {
    switch (state) {
      case AppState.Ready:
        return MessageKeys.APP_READY;
      case AppState.Starting:
        return MessageKeys.APP_STARTING;
      case AppState.Stopping:
        return MessageKeys.APP_STOPPING;
      default:
        return MessageKeys.APP_STOPPED;
    }
  }

  /** The resource name a key is rendered from. */
  static resource(key: string): string {
    return key.replace(/\./g, '_');
  }
}
