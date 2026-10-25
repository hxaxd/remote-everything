package com.remoteeverything.app

import com.remoteeverything.core.api.CatalogCode
import com.remoteeverything.core.api.CatalogResponse
import com.remoteeverything.core.api.ControlAction
import com.remoteeverything.core.api.ControlCode
import com.remoteeverything.core.api.ControlResponse
import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.Path
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

class CatalogControllerTest {
    private val origin = "https://gateway.example"
    private val identity = controllerIdentity(origin)
    private val path = Path(origin, reachable = true, isPrivate = false)
    private val a = Node("a".repeat(64), "A", listOf(path))
    private val b = Node("b".repeat(64), "B", listOf(path))

    @Test
    fun `a catalog answer arriving after cancellation cannot replace another node`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            lateinit var pending: Continuation<CatalogResponse>
            val client = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String): CatalogResponse =
                    if (nodeId == a.id) suspendCoroutine { pending = it } else controllerCatalog("B")
            }
            val controller = controller(scope, client)
            controller.watchNode(a)
            controller.watchNode(b)
            pending.resume(controllerCatalog("A"))
            assertEquals("B", readyName(controller))
        } finally { scope.cancel() }
    }

    @Test
    fun `a delayed control result cannot replace the next node catalog`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val result = CompletableDeferred<ControlResponse>()
            val client = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String) = controllerCatalog(if (nodeId == a.id) "A" else "B")
                override suspend fun start(nodeId: String, appId: String) = result.await()
            }
            val controller = controller(scope, client)
            controller.watchNode(a)
            controller.control(a, "dsh", true)
            controller.stopWatching()
            controller.watchNode(b)
            result.complete(offlineControl())
            assertEquals("B", readyName(controller))
        } finally { scope.cancel() }
    }

    @Test
    fun `returning to the same node does not revive an earlier view control`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val result = CompletableDeferred<ControlResponse>()
            val client = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String) = controllerCatalog(if (nodeId == a.id) "A" else "B")
                override suspend fun start(nodeId: String, appId: String) = result.await()
            }
            val controller = controller(scope, client)
            controller.watchNode(a)
            controller.control(a, "dsh", true)
            controller.watchNode(b)
            controller.watchNode(a)
            result.complete(offlineControl())
            assertEquals("A", readyName(controller))
        } finally { scope.cancel() }
    }

    @Test
    fun `an in flight status poll cannot overwrite another node with the same app id`() = runBlocking {
        withTimeout(10_000) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            try {
                val requested = CompletableDeferred<Unit>()
                val result = CompletableDeferred<ControlResponse>()
                val client = object : ControllerClient(origin) {
                    override suspend fun catalog(nodeId: String) = controllerCatalog(if (nodeId == a.id) "A" else "B")
                    override suspend fun start(nodeId: String, appId: String) =
                        ControlResponse(true, ControlAction.START, true, true, false, ControlCode.STARTING)
                    override suspend fun status(nodeId: String, appId: String): ControlResponse {
                        requested.complete(Unit)
                        return result.await()
                    }
                }
                val controller = controller(scope, client)
                controller.watchNode(a)
                controller.control(a, "dsh", true)
                requested.await()
                controller.watchNode(b)
                result.complete(ControlResponse(true, ControlAction.STATUS, true, true, true,
                    ControlCode.READY, controllerCatalog("A").apps.single()))
                assertEquals("B", readyName(controller))
            } finally { scope.cancel() }
        }
    }

    @Test
    fun `canceling a catalog does not send its request down another path`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val waiting = CompletableDeferred<CatalogResponse>()
            var fallbackRequests = 0
            val primary = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String) =
                    if (nodeId == a.id) waiting.await() else controllerCatalog("B")
            }
            val secondOrigin = "https://second.example"
            val fallback = object : ControllerClient(secondOrigin) {
                override suspend fun catalog(nodeId: String): CatalogResponse {
                    fallbackRequests++
                    return controllerCatalog("A")
                }
            }
            val multiPathNode = a.copy(paths = listOf(path, path.copy(origin = secondOrigin)))
            val controller = CatalogController(scope,
                NodesController({ if (it.origin == origin) primary else fallback }), { "wifi" },
                { listOf(identity, controllerIdentity(secondOrigin)) }, { id -> if (id == a.id) multiPathNode else b }, {})
            controller.watchNode(multiPathNode)
            controller.watchNode(b)
            assertEquals(0, fallbackRequests)
            assertEquals("B", readyName(controller))
        } finally { scope.cancel() }
    }

    @Test
    fun `the existing catalog answer reports an offline computer`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val client = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String) = CatalogResponse(true, false, CatalogCode.COMPUTER_OFFLINE, emptyList())
            }
            val controller = controller(scope, client)
            controller.watchNode(a)
            assertEquals(CatalogUiState.Offline, controller.catalog.value)
        } finally { scope.cancel() }
    }

    private fun controller(scope: CoroutineScope, client: GatewayClient) = CatalogController(
        scope, NodesController({ client }), { "wifi" }, { listOf(identity) },
        { id -> if (id == a.id) a else b }, {},
    )

    private fun offlineControl() = ControlResponse(false, ControlAction.START, false, false, false, ControlCode.COMPUTER_OFFLINE)

    private fun readyName(controller: CatalogController): String {
        assertTrue("expected a ready catalog, got ${controller.catalog.value}", controller.catalog.value is CatalogUiState.Ready)
        return (controller.catalog.value as CatalogUiState.Ready).apps.single().name
    }
}
