package com.remoteeverything.core.api

import com.remoteeverything.core.identity.Pkcs12
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.util.Date

class IdentityKeyManagerTest {

    @Test
    fun `matches EC key for EC and EC_ prefixed key types`() {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val now = System.currentTimeMillis()
        val name = X500Name("CN=client")
        val builder = JcaX509v3CertificateBuilder(
            name,
            BigInteger.valueOf(now),
            Date(now - 60_000),
            Date(now + 86_400_000),
            name,
            keyPair.public,
        )
        val cert = JcaX509CertificateConverter().getCertificate(
            builder.build(JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private)),
        )
        val material = Pkcs12.Material(keyPair.private, listOf(cert))
        val manager = IdentityKeyManager("my-alias", material)

        // Matches EC and EC_EC
        assertArrayEquals(arrayOf("my-alias"), manager.getClientAliases("EC", null))
        assertArrayEquals(arrayOf("my-alias"), manager.getClientAliases("EC_EC", null))
        assertArrayEquals(arrayOf("my-alias"), manager.getClientAliases("ec_rsa", null))

        // Rejects mismatched family like RSA
        assertArrayEquals(emptyArray(), manager.getClientAliases("RSA", null))
        assertNull(manager.chooseClientAlias(arrayOf("RSA"), null, null))

        // Chooses alias when EC is in requested array
        assertEquals("my-alias", manager.chooseClientAlias(arrayOf("RSA", "EC"), null, null))

        // Correctly returns keys and chains only for its alias
        assertEquals(material.privateKey, manager.getPrivateKey("my-alias"))
        assertNull(manager.getPrivateKey("other-alias"))
        assertArrayEquals(material.chain.toTypedArray(), manager.getCertificateChain("my-alias"))
        assertNull(manager.getCertificateChain("other-alias"))
    }
}
