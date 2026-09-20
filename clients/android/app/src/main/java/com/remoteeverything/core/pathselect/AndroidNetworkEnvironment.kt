package com.remoteeverything.core.pathselect

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

    /** Nothing to send on at all: every connection fails the same way, and this says why. */
    fun offline(): Boolean = currentKey() == "offline"

    /**
     * The network as a report should print it. Tokens rather than prose, because a
     * reader who has the phone in hand reads `wifi · internet ✓ · vpn ✗` faster than
     * a sentence — and the marks do not need translating.
     */
    fun describe(): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "unknown"
        val network = manager.activeNetwork ?: return "offline"
        val capabilities = manager.getNetworkCapabilities(network) ?: return "unknown"
        val transport = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
        val internet = if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) "✓" else "✗"
        val vpn = if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) "✓" else "✗"
        return "$transport · internet $internet · vpn $vpn"
    }
}
