package com.remoteeverything.core.api

import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.LinkKind
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.Path

/**
 * Merge every identity's /nodes answer into the single list the UI shows:
 * one row per node id, with one path per gateway that serves it. Order is
 * stable — first appearance across identities, in identity order.
 */
fun mergeNodes(answers: List<Pair<Identity, NodesResponse>>): List<Node> {
    val byId = LinkedHashMap<String, Node>()
    for ((identity, response) in answers) {
        val isPrivate = isPrivateOrigin(identity.origin)
        for (dto in response.nodes) {
            // A gateway that declared how it reaches the node is believed; one that
            // said nothing leaves the client to judge by the address it dials. Either
            // way a path that leaves the local network reads as a tunnel, because
            // that is what it costs the person using it.
            val declaredTunnel = dto.link == "tunnel"
            val path = Path(
                origin = identity.origin,
                identityRef = identity.credentialRef,
                isPrivate = isPrivate,
                link = if (declaredTunnel || !isPrivate) LinkKind.TUNNEL else LinkKind.LOCAL,
            )
            val existing = byId[dto.id]
            byId[dto.id] = if (existing == null) {
                Node(dto.id, dto.name, listOf(path))
            } else {
                existing.copy(paths = existing.paths + path)
            }
        }
    }
    return byId.values.toList()
}

/** Whether an origin's host is a private address (RFC1918, link-local, loopback). */
fun isPrivateOrigin(origin: String): Boolean {
    val withoutScheme = origin.removePrefix("https://")
    val host = if (withoutScheme.startsWith("[")) {
        val closeBracket = withoutScheme.indexOf(']')
        if (closeBracket != -1) withoutScheme.substring(1, closeBracket) else withoutScheme
    } else {
        withoutScheme.substringBefore(':')
    }
    return isPrivateHost(host)
}

fun isPrivateHost(host: String): Boolean {
    val value = host.lowercase().trim().removePrefix("[").removeSuffix("]")
    if (value.contains(":")) {
        // IPv6: loopback, link-local (fe80::/10) and unique-local (fc00::/7).
        if (value == "::1") return true
        if (value.startsWith("fe8") || value.startsWith("fe9") || value.startsWith("fea") || value.startsWith("feb")) {
            return true
        }
        return value.startsWith("fc") || value.startsWith("fd")
    }
    val parts = value.split('.')
    if (parts.size != 4) return false
    val octets = parts.map { it.toIntOrNull() ?: return false }
    if (octets.any { it !in 0..255 }) return false
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] in 16..31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254) ||
        octets[0] == 127
}
