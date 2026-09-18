package com.remoteeverything.core.api

import com.remoteeverything.core.json.Strict

/**
 * What a decoded body must mean, on top of the shape the strict decoder already
 * guaranteed. The contract describes these rules in words — a connected catalog
 * says ready, an offline one lists nothing, a state code says what its flags do —
 * and every platform enforces them, against the same `wire-cases.json` fixture.
 */
object Wire {

    fun validateNodes(response: NodesResponse) {
        require(response.ok) { "a nodes answer says it is not ok" }
        for (node in response.nodes) {
            require(Strict.isHex64(node.id)) { "a node id is not 64 lowercase hex" }
            require(node.name.isNotEmpty()) { "a node name is empty" }
        }
    }

    fun validateCatalog(response: CatalogResponse) {
        require(response.ok) { "a catalog says it is not ok" }
        when (response.code) {
            CatalogCode.READY -> require(response.computer_connected) { "a ready catalog is connected" }
            CatalogCode.COMPUTER_OFFLINE -> require(!response.computer_connected) { "an offline catalog is disconnected" }
        }
        if (!response.computer_connected) {
            require(response.apps.isEmpty()) { "an offline catalog lists applications" }
        }
        val ids = HashSet<String>()
        for (app in response.apps) {
            validateApp(app)
            require(ids.add(app.id)) { "two applications share the id ${app.id}" }
        }
    }

    fun validateApp(app: AppDto) {
        require(Strict.isApplicationId(app.id)) { "an application id is not a valid name" }
        require(app.name.isNotEmpty() && Strict.codePoints(app.name) <= 80) { "an application name is out of bounds" }
        require(Strict.hasNoControlCharacters(app.name)) { "an application name carries control characters" }
        require(Strict.hasNoControlCharacters(app.description)) { "an application description carries control characters" }
        require(Strict.codePoints(app.description) <= 240) { "an application description is out of bounds" }
        require(Strict.codePoints(app.icon) <= 4) { "an application icon is out of bounds" }
        require(Strict.isAccent(app.accent)) { "an application accent is not #RRGGBB" }
        require(Strict.isLaunchFragment(app.launch_fragment)) { "an application launch fragment is not a fragment" }
        require(app.computer_connected) { "an application in a catalog is not connected" }
        require(flagsMatch(app.code, app.enabled, app.running)) { "an application code contradicts its flags" }
    }

    fun validateControl(response: ControlResponse) {
        if (response.computer_connected) {
            require(flagsMatch(response.code, response.enabled, response.running)) {
                "a control code contradicts its flags"
            }
        }
        response.error_code?.let { require(it == "stop_command_failed") { "an unknown error_code $it" } }
        response.app?.let { validateApp(it) }
    }

    fun validatePairing(response: PairingResponse) {
        require(response.ok) { "a pairing answer says it is not ok" }
        require(response.device_name.isNotEmpty()) { "a pairing answer echoes an empty device name" }
        require(Strict.isHex64(response.certificate_fingerprint)) { "a pairing fingerprint is not 64 lowercase hex" }
        require(response.credential_format == "pkcs12") { "a pairing credential is not pkcs12" }
        require(Strict.isBase64(response.credential_pkcs12)) { "a pairing credential is not base64" }
        require(Strict.isRfc3339(response.pending_expires_at)) { "a pairing expiry is not an RFC 3339 instant" }
    }

    fun validateError(response: ErrorResponse) {
        require(!response.ok) { "a refusal says it is ok" }
    }

    /** Whether a state code says what its flags do: the four allowed combinations. */
    private fun flagsMatch(code: AppCode, enabled: Boolean, running: Boolean): Boolean = when (code) {
        AppCode.READY -> enabled && running
        AppCode.STARTING -> enabled && !running
        AppCode.STOPPING -> !enabled && running
        AppCode.STOPPED -> !enabled && !running
    }

    /** A control code's flags, for the four states that name a state; the others say nothing about them. */
    private fun flagsMatch(code: ControlCode, enabled: Boolean, running: Boolean): Boolean = when (code) {
        ControlCode.READY -> enabled && running
        ControlCode.STARTING -> enabled && !running
        ControlCode.STOPPING -> !enabled && running
        ControlCode.STOPPED -> !enabled && !running
        ControlCode.COMPUTER_OFFLINE, ControlCode.APP_NOT_FOUND, ControlCode.STATE_UPDATE_FAILED -> true
    }
}
