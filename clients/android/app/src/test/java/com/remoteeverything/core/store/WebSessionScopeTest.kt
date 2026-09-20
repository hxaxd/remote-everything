package com.remoteeverything.core.store

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class WebSessionScopeTest {
    @Serializable
    private data class Case(val gatewayOrigin: String, val appKey: String, val profile: String, val uuid: String)

    @Test fun `gateway node and application each partition persistent browser data`() {
        val cases = Json.decodeFromString<List<Case>>(File("../../behavior/fixtures/web-session-scope.json").readText())
        for (case in cases) {
            assertEquals(case.profile, WebSessionScope.profileName(case.gatewayOrigin, case.appKey))
        }
        assertEquals(cases.size, cases.map { WebSessionScope.profileName(it.gatewayOrigin, it.appKey) }.toSet().size)
    }

    @Test fun `ambiguous scope inputs are rejected`() {
        assertThrows(IllegalArgumentException::class.java) { WebSessionScope.profileName("https://a\nb", "node/app") }
        assertThrows(IllegalArgumentException::class.java) { WebSessionScope.profileName("https://a", "") }
    }
}
