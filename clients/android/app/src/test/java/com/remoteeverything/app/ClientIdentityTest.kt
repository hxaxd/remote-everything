package com.remoteeverything.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import java.security.PrivateKey
import java.security.cert.X509Certificate

class ClientIdentityTest {
    private val key = object : PrivateKey {
        override fun getAlgorithm() = "EC"
        override fun getFormat() = "PKCS#8"
        override fun getEncoded() = byteArrayOf(1)
    }

    @Test
    fun keyManagerOnlyOffersTheStoredClientKeyForCompatibleTlsTypes() {
        val manager = StaticIdentityKeyManager(key, emptyArray<X509Certificate>())
        val alias = manager.chooseClientAlias(arrayOf("EC_EC", "RSA"), null, null)
        assertEquals("remote-everything", alias)
        assertSame(key, manager.getPrivateKey(alias))
        assertNull(manager.chooseClientAlias(arrayOf("RSA"), null, null))
        assertNull(manager.chooseServerAlias("EC", null, null))
    }
}
