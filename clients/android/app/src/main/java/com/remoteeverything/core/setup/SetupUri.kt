package com.remoteeverything.core.setup

import java.net.URI

/**
 * Strict parser for the remote-everything://setup invitation URI, mirroring
 * contracts/setup-uri.schema.json: exactly the known parameters, each exactly
 * once, each shaped as the schema says. An invitation that does not parse
 * cleanly is not an invitation.
 */
object SetupUri {

    data class Invitation(
        val node: String,
        val nodeName: String,
        val origin: String,
        val invitation: String,
        val serverPin: ServerPin?,
    ) {
        data class ServerPin(val certFingerprint: String, val publicKeyPin: String)
    }

    class Rejected(val reason: String) : Exception(reason)

    private val nodeId = Regex("^[a-f0-9]{64}$")
    private val invitationToken = Regex("^[A-Za-z0-9_-]{43}$")
    private val origin = Regex("^https://[^/?#]+$")
    private val hexFingerprint = Regex("^[a-f0-9]{64}$")
    private val spkiPin = Regex("^[A-Za-z0-9+/]{43}=$")
    private val c0OrDel = Regex("[\\u0000-\\u001F\\u007F]")

    private val knownKeys = setOf("node", "node_name", "origin", "invitation", "fingerprint", "public_key_pin")

    fun parse(text: String): Invitation {
        val trimmed = text.trim()
        val uri = try {
            URI(trimmed)
        } catch (e: Exception) {
            throw Rejected("not a URI")
        }
        if (uri.scheme != "remote-everything" || uri.host != "setup") {
            throw Rejected("not a setup URI")
        }
        if (!uri.path.isNullOrEmpty() && uri.path != "/") {
            throw Rejected("setup URI carries a path")
        }
        if (uri.rawFragment != null || trimmed.contains('#')) {
            throw Rejected("setup URI carries a fragment")
        }
        val params = linkedMapOf<String, String>()
        val query = uri.rawQuery ?: throw Rejected("no parameters")
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            if (eq <= 0) throw Rejected("malformed parameter")
            val key = pair.substring(0, eq)
            if (key !in knownKeys) throw Rejected("unknown parameter: $key")
            if (params.put(key, decode(pair.substring(eq + 1))) != null) {
                throw Rejected("duplicate parameter: $key")
            }
        }
        for (required in listOf("node", "node_name", "origin", "invitation")) {
            if (required !in params) throw Rejected("missing parameter: $required")
        }
        val node = params.getValue("node")
        if (!nodeId.matches(node)) throw Rejected("bad node id")
        val nodeName = params.getValue("node_name")
        if (nodeName.isEmpty() || nodeName.codePointCount(0, nodeName.length) > 80 ||
            nodeName != nodeName.trim() || c0OrDel.containsMatchIn(nodeName)
        ) {
            throw Rejected("bad node name")
        }
        val originValue = params.getValue("origin")
        if (!isValidOrigin(originValue)) throw Rejected("bad origin")
        val invitation = params.getValue("invitation")
        if (!invitationToken.matches(invitation)) throw Rejected("bad invitation")
        val fingerprint = params["fingerprint"]
        val pin = params["public_key_pin"]
        if ((fingerprint == null) != (pin == null)) {
            throw Rejected("fingerprint and public_key_pin travel together")
        }
        if (fingerprint != null && !hexFingerprint.matches(fingerprint)) throw Rejected("bad fingerprint")
        if (pin != null && !spkiPin.matches(pin)) throw Rejected("bad public_key_pin")
        return Invitation(
            node = node,
            nodeName = nodeName,
            origin = originValue,
            invitation = invitation,
            serverPin = if (fingerprint != null && pin != null) {
                Invitation.ServerPin(fingerprint, pin)
            } else {
                null
            },
        )
    }

    /**
     * Percent-decoding with form semantics ('+' is a space), hand-rolled on
     * purpose: this is a security boundary, and the platform decoder's charset
     * overload needs API 33. Bytes are collected and decoded as UTF-8 once, so
     * multi-byte escapes work.
     */
    private fun decode(value: String): String {
        val bytes = java.io.ByteArrayOutputStream(value.length)
        fun flushLiteral(from: Int, to: Int) {
            if (to > from) bytes.write(value.substring(from, to).toByteArray(Charsets.UTF_8))
        }
        var i = 0
        var literalStart = 0
        while (i < value.length) {
            when (value[i]) {
                '%' -> {
                    if (i + 2 >= value.length) throw Rejected("bad encoding")
                    flushLiteral(literalStart, i)
                    val byte = value.substring(i + 1, i + 3).toIntOrNull(16) ?: throw Rejected("bad encoding")
                    bytes.write(byte)
                    i += 3
                    literalStart = i
                }
                '+' -> {
                    flushLiteral(literalStart, i)
                    bytes.write(' '.code)
                    i += 1
                    literalStart = i
                }
                else -> i += 1
            }
        }
        flushLiteral(literalStart, value.length)
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }

    private fun isValidOrigin(value: String): Boolean {
        if (!value.startsWith("https://")) return false
        val authority = value.removePrefix("https://")
        if (authority.isEmpty()) return false
        if (authority.contains('/') || authority.contains('?') || authority.contains('#')) return false
        if (authority.contains('@')) return false
        val colon = authority.lastIndexOf(':')
        val host: String
        val portStr: String?
        if (colon >= 0) {
            host = authority.substring(0, colon)
            portStr = authority.substring(colon + 1)
        } else {
            host = authority
            portStr = null
        }
        if (host.isEmpty()) return false
        if (portStr != null) {
            if (portStr.isEmpty() || !portStr.all { it.isDigit() }) return false
            val port = portStr.toIntOrNull() ?: return false
            if (port !in 1..65535) return false
        }
        return true
    }
}
