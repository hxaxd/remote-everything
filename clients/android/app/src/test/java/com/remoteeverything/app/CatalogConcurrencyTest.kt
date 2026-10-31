package com.remoteeverything.app

import com.remoteeverything.core.api.*
import com.remoteeverything.core.model.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class CatalogConcurrencyTest {
    private val origin = "https://gateway.example"
    private val identity = controllerIdentity(origin)
    private val node = Node("a".repeat(64), "A", listOf(Path(origin, reachable = true, isPrivate = false)))

    @Test fun retryWaitsForRoutesAndDoesNotReviveAnOldVisit() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            var reads = 0
            val client = object : ControllerClient(origin) {
                override suspend fun catalog(nodeId: String): CatalogResponse {
                    reads++
                    return controllerCatalog("DSH")
                }
            }
            val controller = CatalogController(scope, NodesController({ client }), { "wifi" },
                { listOf(identity) }, { node }, {})
            controller.watchNode(node)
            val routes = CompletableDeferred<Unit>()
            controller.recheckAfter { routes.await() }
            assertEquals(1, reads)
            routes.complete(Unit)
            yield()
            assertEquals(2, reads)

            val stale = CompletableDeferred<Unit>()
            controller.recheckAfter { stale.await() }
            controller.stopWatching()
            controller.watchNode(node)
            stale.complete(Unit)
            yield()
            assertEquals("An old retry must not restart a new visit", 3, reads)
        } finally { scope.cancel() }
    }

    @Test fun olderCatalogMustNotUndoCompletedControl() = runBlocking {
        withTimeout(10000) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            try {
                val old = CompletableDeferred<CatalogResponse>()
                val oldRequested = CompletableDeferred<Unit>()
                val freshApplied = CompletableDeferred<Unit>()
                var reads = 0
                var stopped = false
                fun answer() = controllerCatalog("DSH", if (stopped) AppCode.STOPPED else AppCode.READY).let {
                    it.copy(apps = it.apps + it.apps[0].copy(id = "other"))
                }
                val client = object : ControllerClient(origin) {
                    override suspend fun catalog(nodeId: String): CatalogResponse {
                        when (++reads) {
                            2 -> { oldRequested.complete(Unit); return old.await() }
                            3 -> freshApplied.complete(Unit)
                        }
                        return answer()
                    }
                    override suspend fun start(nodeId: String, appId: String) = ControlResponse(true,ControlAction.START,true,true,true,ControlCode.READY)
                    override suspend fun stop(nodeId: String, appId: String): ControlResponse {
                        stopped = true
                        return ControlResponse(true,ControlAction.STOP,true,false,false,ControlCode.STOPPED)
                    }
                    override suspend fun status(nodeId: String, appId: String) = if (appId == "dsh" && stopped)
                        ControlResponse(true,ControlAction.STATUS,true,false,false,ControlCode.STOPPED)
                    else ControlResponse(true,ControlAction.STATUS,true,true,true,ControlCode.READY)
                }
                val c = CatalogController(scope,NodesController({ client }),{"wifi"},{listOf(identity)},{node},{})
                c.watchNode(node)
                val staleAnswer = answer()
                c.control(node,"other",true)
                oldRequested.await()
                c.control(node,"dsh",false)
                freshApplied.await(); yield()
                assertEquals(AppState.STOPPED,(c.catalog.value as CatalogUiState.Ready).apps[0].code)
                old.complete(staleAnswer); yield()
                assertEquals("Late catalog must not undo confirmed stop",AppState.STOPPED,(c.catalog.value as CatalogUiState.Ready).apps[0].code)
            } finally { scope.cancel() }
        }
    }

    @Test fun actualStopCommandFailureMustBeReported() = runBlocking {
        withTimeout(10000) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            try {
                val done = CompletableDeferred<Unit>()
                val notices = mutableListOf<Int>()
                var reads = 0
                val client = object : ControllerClient(origin) {
                    override suspend fun catalog(nodeId: String): CatalogResponse {
                        if (++reads > 1) done.complete(Unit)
                        return controllerCatalog("DSH",AppCode.STOPPED)
                    }
                    override suspend fun stop(nodeId: String,appId: String) = ControlResponse(false,ControlAction.STOP,true,false,false,ControlCode.STOPPED,error_code="stop_command_failed")
                    override suspend fun status(nodeId: String,appId: String) = ControlResponse(true,ControlAction.STATUS,true,false,false,ControlCode.STOPPED)
                }
                val c=CatalogController(scope,NodesController({client}),{"wifi"},{listOf(identity)},{node},{notices.add(it)})
                c.watchNode(node); c.control(node,"dsh",false)
                done.await(); yield()
                assertTrue("Stop helper failed but no failure notice was emitted",notices.contains(R.string.error_stop_failed))
            } finally { scope.cancel() }
        }
    }
}
