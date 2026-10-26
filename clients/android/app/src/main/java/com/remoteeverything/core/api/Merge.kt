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
    val value = host.lowercase().removeSurrounding("[", "]")
    if (value == "localhost") return true
    if (value.contains(":")) {
        val words = ipv6Words(value) ?: return false
        if (words.take(5).all { it == 0 } && words[5] == 0xffff) {
            return privateOctets(listOf(words[6] shr 8, words[6] and 255, words[7] shr 8, words[7] and 255))
        }
        return words.take(7).all { it == 0 } && words[7] == 1 || words[0] and 0xfe00 == 0xfc00 || words[0] and 0xffc0 == 0xfe80
    }
    return ipv4Octets(value)?.let(::privateOctets) ?: false
}

private fun ipv4Octets(value: String): List<Int>? {
    val parts = value.split('.')
    if (parts.size != 4 || parts.any { !it.matches(Regex("0|[1-9][0-9]{0,2}")) }) return null
    return parts.map { it.toInt() }.takeIf { list -> list.all { it in 0..255 } }
}

private fun privateOctets(octets: List<Int>): Boolean {
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] in 16..31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254) ||
        octets[0] == 127
}

private fun ipv6Words(input: String): List<Int>? {
    var value = input
    if (value.contains('.')) {
        val at = value.lastIndexOf(':')
        val octets = ipv4Octets(value.substring(at + 1)) ?: return null
        value = value.substring(0, at + 1) + ((octets[0] shl 8) + octets[1]).toString(16) + ":" + ((octets[2] shl 8) + octets[3]).toString(16)
    }
    val halves = value.split("::")
    if (halves.size > 2) return null
    fun words(part: String): List<Int>? {
        if (part.isEmpty()) return emptyList()
        val groups = part.split(':')
        if (groups.any { !it.matches(Regex("[0-9a-f]{1,4}")) }) return null
        return groups.map { it.toInt(16) }
    }
    val left = words(halves[0]) ?: return null
    if (halves.size == 1) return left.takeIf { it.size == 8 }
    val right = words(halves[1]) ?: return null
    val missing = 8 - left.size - right.size
    return if (missing > 0) left + List(missing) { 0 } + right else null
}
