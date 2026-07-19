package com.remoteeverything.app

object AppConfig {
    val GATEWAY_HOST = BuildConfig.GATEWAY_HOST
    val GATEWAY_ORIGIN = BuildConfig.GATEWAY_ORIGIN
    val ENROLL_REQUEST_URL = "$GATEWAY_ORIGIN/__remote_everything_enroll/request"
    val ENROLL_STATUS_URL = "$GATEWAY_ORIGIN/__remote_everything_enroll/status"
    val APPS_URL = "$GATEWAY_ORIGIN/__remote_everything/apps"
    val CONTROL_TOKEN = BuildConfig.CONTROL_TOKEN
    val BOOTSTRAP_PASSWORD = BuildConfig.BOOTSTRAP_PASSWORD
    val BOOTSTRAP_FINGERPRINT = BuildConfig.BOOTSTRAP_FINGERPRINT

    fun appActionUrl(id: String, action: String) = "$APPS_URL/$id/$action"
}
