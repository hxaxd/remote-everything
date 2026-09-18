package com.remoteeverything.core.pathselect

/**
 * What the network looks like right now: which paths can be chosen is a property
 * of the network, so a change in this key throws the cached choices away.
 * Pure interface in core so the selector itself stays decoupled from platform SDK.
 */
fun interface NetworkEnvironment {
    fun currentKey(): String
}
