package com.remoteeverything.core.pathselect

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * What the network looks like right now: which paths can be chosen is a property
 * of the network, so a change in this key throws the cached choices away. The
 * one platform piece of path selection, kept in core so the selector itself
 * stays pure.
 */
object NetworkEnvironment {

    fun key(context: Context): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "unknown"
        val network = manager.activeNetwork ?: return "offline"
        val capabilities = manager.getNetworkCapabilities(network)
        val kind = when {
            capabilities == null -> "unknown"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        return "$kind-${network.toString().hashCode()}"
    }
}
