package com.remoteeverything.app.i18n

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.remoteeverything.app.R
import com.remoteeverything.core.model.MessageKeys

/**
 * The one place a canonical message key becomes a platform resource. A resource
 * carries the key's name with dots replaced by underscores (`pair.scan` →
 * `pair_scan`), and this table is the mapping kept by the behaviour test that
 * compares every MessageKeys constant against message-keys.json and both
 * languages' resources. A key without a resource fails here, loudly, rather
 * than rendering nothing.
 */
@StringRes
fun messageKey(key: String): Int = when (key) {
    MessageKeys.ACTION_ADD_NODE -> R.string.action_add_node
    MessageKeys.ACTION_BACK -> R.string.action_back
    MessageKeys.ACTION_BACK_TO_NODES -> R.string.action_back_to_nodes
    MessageKeys.ACTION_CANCEL -> R.string.action_cancel
    MessageKeys.ACTION_CONFIRM -> R.string.action_confirm
    MessageKeys.ACTION_DONE -> R.string.action_done
    MessageKeys.ACTION_RETRY -> R.string.action_retry
    MessageKeys.ACTION_START -> R.string.action_start
    MessageKeys.ACTION_STOP -> R.string.action_stop
    MessageKeys.APP_NAME -> R.string.app_name
    MessageKeys.APP_OPEN_FAILED -> R.string.app_open_failed
    MessageKeys.APP_READY -> R.string.app_ready
    MessageKeys.APP_STARTING -> R.string.app_starting
    MessageKeys.APP_STOPPED -> R.string.app_stopped
    MessageKeys.APP_STOPPING -> R.string.app_stopping
    MessageKeys.APPS_EMPTY_BODY -> R.string.apps_empty_body
    MessageKeys.APPS_EMPTY_TITLE -> R.string.apps_empty_title
    MessageKeys.DEVICE_CATEGORY_DEFAULT -> R.string.device_category_default
    MessageKeys.DEVICE_CATEGORY_PHONE -> R.string.device_category_phone
    MessageKeys.DEVICE_CATEGORY_TABLET -> R.string.device_category_tablet
    MessageKeys.EMPTY_BODY -> R.string.empty_body
    MessageKeys.EMPTY_TITLE -> R.string.empty_title
    MessageKeys.ERROR_APP_GONE -> R.string.error_app_gone
    MessageKeys.ERROR_BUSY -> R.string.error_busy
    MessageKeys.ERROR_CLIENT -> R.string.error_client
    MessageKeys.ERROR_CONTROL_FAILED -> R.string.error_control_failed
    MessageKeys.ERROR_CREDENTIAL_LOST -> R.string.error_credential_lost
    MessageKeys.ERROR_NETWORK -> R.string.error_network
    MessageKeys.ERROR_NODE_GONE -> R.string.error_node_gone
    MessageKeys.ERROR_NODE_GONE_BODY -> R.string.error_node_gone_body
    MessageKeys.ERROR_NOT_FOUND -> R.string.error_not_found
    MessageKeys.ERROR_STOP_FAILED -> R.string.error_stop_failed
    MessageKeys.IDENTITY_NEEDS_PAIRING -> R.string.identity_needs_pairing
    MessageKeys.IDENTITY_NEEDS_PAIRING_BODY -> R.string.identity_needs_pairing_body
    MessageKeys.IDENTITY_NEEDS_PAIRING_TITLE -> R.string.identity_needs_pairing_title
    MessageKeys.IDENTITY_UNAUTHORIZED -> R.string.identity_unauthorized
    MessageKeys.LANGUAGE_EN -> R.string.language_en
    MessageKeys.LANGUAGE_ZH -> R.string.language_zh
    MessageKeys.NODE_LAN -> R.string.node_lan
    MessageKeys.NODE_OFFLINE -> R.string.node_offline
    MessageKeys.NODE_OFFLINE_BODY -> R.string.node_offline_body
    MessageKeys.NODE_OFFLINE_TITLE -> R.string.node_offline_title
    MessageKeys.NODE_PENDING -> R.string.node_pending
    MessageKeys.NODE_TUNNEL -> R.string.node_tunnel
    MessageKeys.NODE_UNKNOWN -> R.string.node_unknown
    MessageKeys.NODES_SELECT_HINT -> R.string.nodes_select_hint
    MessageKeys.NODES_TITLE -> R.string.nodes_title
    MessageKeys.PAIR_ACTION_JOIN -> R.string.pair_action_join
    MessageKeys.PAIR_BAD_INVITATION -> R.string.pair_bad_invitation
    MessageKeys.PAIR_CONFIRM_BODY -> R.string.pair_confirm_body
    MessageKeys.PAIR_DENIED -> R.string.pair_denied
    MessageKeys.PAIR_DEVICE_NAME -> R.string.pair_device_name
    MessageKeys.PAIR_DEVICE_NAME_HINT -> R.string.pair_device_name_hint
    MessageKeys.PAIR_DEVICE_NAME_REQUIRED -> R.string.pair_device_name_required
    MessageKeys.PAIR_EXPIRED -> R.string.pair_expired
    MessageKeys.PAIR_GATEWAY_LABEL -> R.string.pair_gateway_label
    MessageKeys.PAIR_GATEWAY_TROUBLE -> R.string.pair_gateway_trouble
    MessageKeys.PAIR_INPUT_HINT -> R.string.pair_input_hint
    MessageKeys.PAIR_NETWORK -> R.string.pair_network
    MessageKeys.PAIR_NODE_LABEL -> R.string.pair_node_label
    MessageKeys.PAIR_SCAN -> R.string.pair_scan
    MessageKeys.PAIR_SCAN_BODY -> R.string.pair_scan_body
    MessageKeys.PAIR_SCAN_DENIED -> R.string.pair_scan_denied
    MessageKeys.PAIR_SCAN_FAILED -> R.string.pair_scan_failed
    MessageKeys.PAIR_TITLE -> R.string.pair_title
    MessageKeys.PAIR_WAITING_APPROVAL -> R.string.pair_waiting_approval
    MessageKeys.PAIR_WORKING -> R.string.pair_working
    MessageKeys.SETTINGS_ABOUT -> R.string.settings_about
    MessageKeys.SETTINGS_APPEARANCE -> R.string.settings_appearance
    MessageKeys.SETTINGS_APPEARANCE_DARK -> R.string.settings_appearance_dark
    MessageKeys.SETTINGS_APPEARANCE_LIGHT -> R.string.settings_appearance_light
    MessageKeys.SETTINGS_APPEARANCE_SYSTEM -> R.string.settings_appearance_system
    MessageKeys.SETTINGS_CERTIFICATE_FINGERPRINT -> R.string.settings_certificate_fingerprint
    MessageKeys.SETTINGS_DEVICE_NAME -> R.string.settings_device_name
    MessageKeys.SETTINGS_FORGET -> R.string.settings_forget
    MessageKeys.SETTINGS_FORGET_CONFIRM -> R.string.settings_forget_confirm
    MessageKeys.SETTINGS_IDENTITIES -> R.string.settings_identities
    MessageKeys.SETTINGS_LANGUAGE -> R.string.settings_language
    MessageKeys.SETTINGS_LANGUAGE_SYSTEM -> R.string.settings_language_system
    MessageKeys.SETTINGS_NO_IDENTITIES -> R.string.settings_no_identities
    MessageKeys.SETTINGS_NODES_COUNT -> R.string.settings_nodes_count
    MessageKeys.SETTINGS_PROTOCOL_VERSION -> R.string.settings_protocol_version
    MessageKeys.SETTINGS_TITLE -> R.string.settings_title
    MessageKeys.SETTINGS_UPDATES -> R.string.settings_updates
    MessageKeys.SETTINGS_UPDATES_AVAILABLE -> R.string.settings_updates_available
    MessageKeys.SETTINGS_UPDATES_CHECK -> R.string.settings_updates_check
    MessageKeys.SETTINGS_UPDATES_CHECKING -> R.string.settings_updates_checking
    MessageKeys.SETTINGS_UPDATES_CURRENT -> R.string.settings_updates_current
    MessageKeys.SETTINGS_UPDATES_FAILED -> R.string.settings_updates_failed
    MessageKeys.SETTINGS_UPDATES_NONE -> R.string.settings_updates_none
    MessageKeys.SETTINGS_UPDATES_PROTOCOL -> R.string.settings_updates_protocol
    MessageKeys.SETTINGS_UPDATES_STORE_HINT -> R.string.settings_updates_store_hint
    MessageKeys.SETTINGS_VERSION -> R.string.settings_version
    MessageKeys.WEB_LOAD_FAILED -> R.string.web_load_failed
    MessageKeys.WEB_LOADING -> R.string.web_loading
    else -> error("no resource for message key $key")
}

/** The key's sentence, in the device's language. */
@Composable
fun l10n(key: String): String = stringResource(messageKey(key))

/** The key's sentence with arguments, in the device's language. */
@Composable
fun l10n(key: String, vararg args: Any): String = stringResource(messageKey(key), *args)
