package com.remoteeverything.core.store

import com.remoteeverything.core.api.NodesResponse
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The last good /nodes answer per gateway, so a cold start shows the machines
 * there were a moment ago before the first probe answers. Not truth — the wire
 * rebuilds the list on every refresh — but the difference between an empty
 * screen and the machines you had.
 */
class NodeCacheStore(private val file: File) {

    private val json = Json { ignoreUnknownKeys = false }
    private val serializer = MapSerializer(String.serializer(), NodesResponse.serializer())

    fun load(): Map<String, NodesResponse> = AtomicFile.read(file)?.let { raw ->
        runCatching { json.decodeFromString(serializer, raw.toString(Charsets.UTF_8)) }.getOrNull()
    } ?: emptyMap()

    fun save(cache: Map<String, NodesResponse>) {
        if (cache.isEmpty()) return
        AtomicFile.write(file, json.encodeToString(serializer, cache).toByteArray(Charsets.UTF_8))
    }
}
