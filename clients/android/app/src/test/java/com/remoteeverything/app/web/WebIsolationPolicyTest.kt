package com.remoteeverything.app.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WebIsolationPolicyTest {
    @Test
    fun profileNamesAreStableAndSeparatedByInstallationAndApp() {
        val installation = "ab".repeat(32)
        val kimi = WebIsolationPolicy.profileName(installation, "kimi")

        assertEquals(kimi, WebIsolationPolicy.profileName(installation, "kimi"))
        assertNotEquals(kimi, WebIsolationPolicy.profileName(installation, "cloudcli"))
        assertNotEquals(kimi, WebIsolationPolicy.profileName("cd".repeat(32), "kimi"))
        assertTrue(kimi.matches(Regex("^remote-[a-f0-9]{64}$")))
    }

    @Test
    fun routingCookieMatchesGatewayContract() {
        assertEquals(
            "RemoteEverythingApp=kimi; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400",
            WebIsolationPolicy.routingCookie("kimi"),
        )
    }
}
