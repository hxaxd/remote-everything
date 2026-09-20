package com.remoteeverything.core.store

import kotlinx.serialization.Serializable

/** How one application's web host holds the screen. */
enum class WebOrientation { SYSTEM, PORTRAIT, LANDSCAPE }

/** Which user agent one application's web host introduces itself with. */
enum class WebUserAgent { MOBILE, DESKTOP }

/**
 * What the web host remembers for one application, keyed by `nodeId/appId`:
 * the choices on the in-app panel, kept across visits. Defaults are what an
 * application gets until its panel is touched: the system decides the
 * orientation, and the page sees the mobile user agent.
 */
@Serializable
data class WebAppPrefs(
    val orientation: WebOrientation = WebOrientation.SYSTEM,
    val userAgent: WebUserAgent = WebUserAgent.MOBILE,
)
