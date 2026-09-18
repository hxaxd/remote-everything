package com.remoteeverything.core.api

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A certificate speaks for a host or it does not: an exact name, or a wildcard
 * that covers exactly one label. A suffix match is how `evil-example.com` would
 * speak for `example.com`.
 */
class HostNameTest {

    @Test
    fun `an exact name matches itself`() {
        assertTrue(dnsNameMatches("gw.example.com", "gw.example.com"))
        assertFalse(dnsNameMatches("gw.example.com", "other.example.com"))
    }

    @Test
    fun `a wildcard covers exactly one label`() {
        assertTrue(dnsNameMatches("*.example.com", "a.example.com"))
        assertTrue(dnsNameMatches("*.example.com", "a1b2c3d4.example.com"))
    }

    @Test
    fun `a wildcard does not cover the bare domain`() {
        assertFalse(dnsNameMatches("*.example.com", "example.com"))
    }

    @Test
    fun `a wildcard does not cover two labels`() {
        assertFalse(dnsNameMatches("*.example.com", "a.b.example.com"))
    }

    @Test
    fun `a name is never a suffix match`() {
        assertFalse(dnsNameMatches("example.com", "evil-example.com"))
        assertFalse(dnsNameMatches("example.com", "example.com.evil.net"))
    }
}
