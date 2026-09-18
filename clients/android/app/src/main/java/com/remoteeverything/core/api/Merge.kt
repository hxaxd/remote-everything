package com.remoteeverything.core.api

import com.remoteeverything.core.model.Identity
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
            val path = Path(
                origin = identity.origin,
                isPrivate = isPrivate,
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
    val host = origin.removePrefix("https://").substringBefore(':')
    val parts = host.split('.')
    if (parts.size != 4) return false
    val octets = parts.map { it.toIntOrNull() ?: return false }
    if (octets.any { it !in 0..255 }) return false
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] in 16..31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254) ||
        octets[0] == 127
}
