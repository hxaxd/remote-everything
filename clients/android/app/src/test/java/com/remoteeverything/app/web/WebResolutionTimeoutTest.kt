package com.remoteeverything.app.web

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class WebResolutionTimeoutTest {
    @Test fun ownDeadlineBecomesDisplayableFailure() = runBlocking {
        try {
            withWebResolutionTimeout(20) { awaitCancellation() }
            fail("resolution must expire")
        } catch (error: Exception) {
            assertTrue("deadline must reach the failure UI", error !is CancellationException)
        }
    }

    @Test fun leavingPageStillCancelsSilently() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val job = async {
            withWebResolutionTimeout {
                entered.complete(Unit)
                awaitCancellation()
            }
        }
        entered.await()
        job.cancel()
        try {
            job.await()
            fail("parent cancellation must propagate")
        } catch (_: CancellationException) { }
    }

    @Test fun resolvedPagePassesThrough() = runBlocking {
        assertEquals("https://app.example", withWebResolutionTimeout { "https://app.example" })
    }
}
