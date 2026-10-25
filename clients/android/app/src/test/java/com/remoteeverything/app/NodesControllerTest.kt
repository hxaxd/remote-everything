package com.remoteeverything.app

import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.store.NodeCacheStore
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NodesControllerTest {
    @get:Rule val temporary = TemporaryFolder()

    private val a = controllerIdentity("https://a.example")
    private val b = controllerIdentity("https://b.example")
    private val aId = "a".repeat(64)
    private val bId = "b".repeat(64)

    @Test
    fun `canceling a refresh is not recorded as a connection failure`() = runBlocking {
        withTimeout(10_000) {
            val requested = CompletableDeferred<Unit>()
            val answer = CompletableDeferred<NodesResponse>()
            val controller = NodesController({ identity -> object : ControllerClient(identity.origin) {
                override suspend fun nodes(): NodesResponse {
                    requested.complete(Unit)
                    return answer.await()
                }
            } })
            val refresh = launch { controller.refresh(listOf(a), "wifi") }
            requested.await()
            refresh.cancelAndJoin()
            assertTrue(controller.trouble.value.isEmpty())
            assertTrue(controller.failedProbesFor(a.origin).isEmpty())
        }
    }

    @Test
    fun `one successful refresh preserves another offline gateway in memory and on disk`() = runBlocking {
        val cache = cache()
        cache.save(mapOf(a.origin to controllerNodes(aId), b.origin to controllerNodes(bId)))
        val controller = NodesController({ identity -> object : ControllerClient(identity.origin) {
            override suspend fun nodes(): NodesResponse {
                if (identity.origin == a.origin) return controllerNodes(aId)
                throw IOException("offline")
            }
        } }, cache)
        val nodes = controller.refresh(listOf(a, b), "wifi")
        assertEquals(setOf(aId, bId), nodes.map { it.id }.toSet())
        assertEquals(false, nodes.single { it.id == bId }.paths.single().reachable)
        assertEquals(setOf(a.origin, b.origin), cache.load().keys)

        val restarted = offlineController(cache).refresh(listOf(a, b), "offline")
        assertEquals(setOf(aId, bId), restarted.map { it.id }.toSet())
    }

    @Test
    fun `concurrent successful gateways retain both cached answers`() = runBlocking {
        val cache = cache()
        val controller = NodesController({ identity -> object : ControllerClient(identity.origin) {
            override suspend fun nodes() = controllerNodes(if (identity.origin == a.origin) aId else bId)
        } }, cache)
        val nodes = controller.refresh(listOf(a, b), "wifi")
        assertTrue(nodes.all { it.paths.single().reachable == true })
        assertEquals(setOf(a.origin, b.origin), cache.load().keys)
    }

    @Test
    fun `forgetting a gateway removes its cold cache without losing the other one`() = runBlocking {
        val cache = cache()
        cache.save(mapOf(a.origin to controllerNodes(aId), b.origin to controllerNodes(bId)))
        val controller = offlineController(cache)
        controller.refresh(listOf(a, b), "offline")
        controller.drop(a.origin)
        assertEquals(setOf(b.origin), cache.load().keys)
        assertEquals(listOf(bId), controller.refresh(listOf(a, b), "offline").map { it.id })
    }

    private fun cache() = NodeCacheStore(File(temporary.root, "nodes.json"))

    private fun offlineController(cache: NodeCacheStore) = NodesController({ identity -> object : ControllerClient(identity.origin) {
        override suspend fun nodes(): NodesResponse = throw IOException("offline")
    } }, cache)
}
