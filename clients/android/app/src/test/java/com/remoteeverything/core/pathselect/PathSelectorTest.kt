package com.remoteeverything.core.pathselect

import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PathSelectorTest {

    private fun path(origin: String, reachable: Boolean?, latency: Long?, isPrivate: Boolean) = Path(
        origin = origin,
        reachable = reachable,
        latencyMs = latency,
        isPrivate = isPrivate,
    )

    private val lan = path("https://192.168.1.10", reachable = true, latency = 5, isPrivate = true)
    private val tunnel = path("https://gw.example.com", reachable = true, latency = 40, isPrivate = false)

    @Test
    fun `a reachable private path beats a public one`() {
        assertEquals(lan, PathSelector.choose(listOf(tunnel, lan)))
    }

    @Test
    fun `lower latency wins within the same class`() {
        val slowTunnel = path("https://slow.example.com", reachable = true, latency = 90, isPrivate = false)
        assertEquals(tunnel, PathSelector.choose(listOf(slowTunnel, tunnel)))
    }

    @Test
    fun `unreachable and unprobed paths are not chosen`() {
        val dead = lan.copy(reachable = false)
        val unprobed = tunnel.copy(reachable = null)
        assertNull(PathSelector.choose(listOf(dead, unprobed)))
    }

    @Test
    fun `an unreachable private path loses to a reachable public one`() {
        assertEquals(tunnel, PathSelector.choose(listOf(lan.copy(reachable = false), tunnel)))
    }

    @Test
    fun `cache sticks while the network is unchanged and the path stays reachable`() {
        val cache = PathSelector.Cache()
        val node = Node("id", "name", listOf(lan, tunnel))
        assertEquals(lan, cache.resolve(node, "wifi-a"))
        // Even with a now-better tunnel, the cached LAN choice sticks.
        assertEquals(lan, cache.resolve(node.copy(paths = listOf(lan, tunnel.copy(latencyMs = 1))), "wifi-a"))
    }

    @Test
    fun `a network change invalidates the cache`() {
        val cache = PathSelector.Cache()
        val node = Node("id", "name", listOf(lan, tunnel))
        assertEquals(lan, cache.resolve(node, "wifi-a"))
        val offlineLan = node.copy(paths = listOf(lan.copy(reachable = false), tunnel))
        assertEquals(tunnel, cache.resolve(offlineLan, "wifi-b"))
    }

    @Test
    fun `a cached choice that became unreachable is re-resolved`() {
        val cache = PathSelector.Cache()
        val node = Node("id", "name", listOf(lan, tunnel))
        assertEquals(lan, cache.resolve(node, "wifi-a"))
        val offlineLan = node.copy(paths = listOf(lan.copy(reachable = false), tunnel))
        assertEquals(tunnel, cache.resolve(offlineLan, "wifi-a"))
    }
}
