package com.remoteeverything.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class CatalogPollerTest {
    @Test
    fun schedulingReplacesTheOnlyPendingCallback() {
        val posted = mutableListOf<Pair<Runnable, Long>>()
        val removed = mutableListOf<Runnable>()
        val poller = CatalogPoller(
            postDelayed = { callback, delay -> posted += callback to delay },
            removeCallbacks = { callback -> removed += callback },
        )
        var executions = 0
        poller.schedule(5_000) { executions += 1 }
        val first = posted.single().first
        poller.schedule(0) { executions += 10 }
        assertEquals(1, removed.size)
        assertSame(first, removed.single())
        posted.last().first.run()
        poller.cancel()
        assertEquals(10, executions)
        assertEquals(1, removed.size)
    }
}
