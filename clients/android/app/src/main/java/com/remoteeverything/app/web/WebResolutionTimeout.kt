package com.remoteeverything.app.web

import kotlinx.coroutines.withTimeoutOrNull

/** An expired resolution shows the page failure UI; leaving the page still cancels silently. */
internal suspend fun <T : Any> withWebResolutionTimeout(
    timeoutMs: Long = 60_000,
    resolve: suspend () -> T,
): T = withTimeoutOrNull(timeoutMs) { resolve() }
    ?: error("application resolution timed out")
