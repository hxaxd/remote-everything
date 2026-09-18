package com.remoteeverything.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.remoteeverything.core.pathselect.NetworkEnvironment

class AndroidNetworkEnvironment(private val context: Context) : NetworkEnvironment {
    override fun currentKey(): String {
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
        return "$kind-${network.hashCode()}"
    }
}
