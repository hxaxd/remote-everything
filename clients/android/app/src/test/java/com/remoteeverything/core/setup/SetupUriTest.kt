package com.remoteeverything.core.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class SetupUriTest {

    private val node = "a".repeat(64)
    private val invitation = "A".repeat(43)
    private val fingerprint = "b".repeat(64)
    private val pin = "C".repeat(43) + "="

    private fun uri(
        node: String = this.node,
        nodeName: String = "客厅电脑",
        origin: String = "https://gateway.example.com",
        invitation: String = this.invitation,
        extra: String = "",
    ) = "remote-everything://setup?node=$node&node_name=${
        java.net.URLEncoder.encode(nodeName, "UTF-8")
    }&origin=$origin&invitation=$invitation$extra"

    @Test
    fun `a minimal invitation parses`() {
        val parsed = SetupUri.parse(uri())
        assertEquals(node, parsed.node)
        assertEquals("客厅电脑", parsed.nodeName)
        assertEquals("https://gateway.example.com", parsed.origin)
        assertEquals(invitation, parsed.invitation)
        assertNull(parsed.serverPin)
    }

    @Test
    fun `fingerprint and pin travel together`() {
        val parsed = SetupUri.parse(uri(extra = "&fingerprint=$fingerprint&public_key_pin=$pin"))
        assertNotNull(parsed.serverPin)
        assertEquals(fingerprint, parsed.serverPin!!.certFingerprint)
        assertEquals(pin, parsed.serverPin!!.publicKeyPin)
    }

    @Test
    fun `fingerprint without pin is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse(uri(extra = "&fingerprint=$fingerprint"))
        }
    }

    @Test
    fun `pin without fingerprint is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse(uri(extra = "&public_key_pin=$pin"))
        }
    }

    @Test
    fun `an unknown parameter is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse(uri(extra = "&v=1"))
        }
    }

    @Test
    fun `a duplicate parameter is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse(uri() + "&node=$node")
        }
    }

    @Test
    fun `a bad node id is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(node = "xyz")) }
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(node = "A".repeat(64))) }
    }

    @Test
    fun `a padded node name is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(nodeName = " padded ")) }
    }

    @Test
    fun `a node name with control characters is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(nodeName = "a\nb")) }
    }

    @Test
    fun `a non-https origin is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(origin = "http://gateway.example.com")) }
    }

    @Test
    fun `an origin with a path is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse(uri(origin = "https://gateway.example.com/path"))
        }
    }

    @Test
    fun `a bad invitation token is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) { SetupUri.parse(uri(invitation = "short")) }
    }

    @Test
    fun `a different scheme is rejected`() {
        assertThrows(SetupUri.Rejected::class.java) {
            SetupUri.parse("https://setup?node=$node&node_name=x&origin=https://a.example.com&invitation=$invitation")
        }
    }

    @Test
    fun `surrounding whitespace is tolerated`() {
        val parsed = SetupUri.parse("  " + uri() + "\n")
        assertEquals(node, parsed.node)
    }

    @Test
    fun `a plus in the node name decodes to a space`() {
        val raw = "remote-everything://setup?node=$node&node_name=living+room&origin=https://a.example.com&invitation=$invitation"
        assertEquals("living room", SetupUri.parse(raw).nodeName)
    }
}
