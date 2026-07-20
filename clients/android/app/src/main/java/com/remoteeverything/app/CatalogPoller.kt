package com.remoteeverything.app

class CatalogPoller(
    private val postDelayed: (Runnable, Long) -> Unit,
    private val removeCallbacks: (Runnable) -> Unit,
) {
    private var pending: Runnable? = null

    fun schedule(delayMillis: Long, action: () -> Unit) {
        cancel()
        val callback = Runnable {
            pending = null
            action()
        }
        pending = callback
        postDelayed(callback, delayMillis)
    }

    fun cancel() {
        pending?.let(removeCallbacks)
        pending = null
    }
}
