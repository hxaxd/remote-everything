package com.remoteeverything.core.store

import com.remoteeverything.core.api.NodeDto
import com.remoteeverything.core.api.NodesResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class NodeCacheStoreTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun `persists and reloads nodes response per origin roundtrip`() {
        val cacheFile = File(tempFolder.root, "nodes_cache.json")
        val store = NodeCacheStore(cacheFile)

        assertEquals(emptyMap<String, NodesResponse>(), store.load())

        val nodes1 = NodesResponse(
            ok = true,
            nodes = listOf(
                NodeDto(id = "n1".padEnd(64, '0'), name = "Desktop"),
                NodeDto(id = "n2".padEnd(64, '0'), name = "Laptop"),
            ),
        )
        val nodes2 = NodesResponse(
            ok = true,
            nodes = listOf(
                NodeDto(id = "n3".padEnd(64, '0'), name = "Server"),
            ),
        )
        val data = mapOf("https://gw1.example.com" to nodes1, "https://gw2.example.com" to nodes2)
        store.save(data)

        assertTrue(cacheFile.exists())
        val loaded = store.load()
        assertEquals(2, loaded.size)
        assertEquals("Desktop", loaded["https://gw1.example.com"]?.nodes?.get(0)?.name)
        assertEquals("Server", loaded["https://gw2.example.com"]?.nodes?.get(0)?.name)

        // Saving empty map deletes cache file
        store.save(emptyMap())
        assertFalse(cacheFile.exists())
        assertEquals(emptyMap<String, NodesResponse>(), store.load())
    }

    @Test
    fun `returns empty map on corrupted cache file`() {
        val cacheFile = File(tempFolder.root, "corrupted_cache.json")
        cacheFile.writeText("{ invalid json [")
        val store = NodeCacheStore(cacheFile)

        assertEquals(emptyMap<String, NodesResponse>(), store.load())
    }
}
