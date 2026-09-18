package com.remoteeverything.core.api

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicReference

/**
 * The one wire rule the review called out: pairing carries the invitation in an
 * Authorization header, because it is the one request a gateway accepts without
 * a credential. A client that drops the header cannot pair at all.
 */
class OkHttpGatewayClientTest {

    @Test
    fun `pairing sends the invitation as the Authorization header`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val received = AtomicReference<String?>(null)
        server.createContext("/__remote_everything_pair") { exchange ->
            received.set(exchange.requestHeaders.getFirst("Authorization"))
            val body = """
                {"ok":true,"device_name":"Pixel",
                 "certificate_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 "credential_format":"pkcs12","credential_pkcs12":"MIIB",
                 "pending_expires_at":"2026-09-17T10:00:00Z"}
            """.trimIndent().replace("\n", "")
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, body.toByteArray().size.toLong())
            exchange.responseBody.use { it.write(body.toByteArray()) }
        }
        server.start()
        try {
            val client = OkHttpGatewayClient(
                origin = "http://127.0.0.1:${server.address.port}",
                material = null,
                serverPin = null,
            )
            client.pair(
                PairRequest(
                    origin = "http://127.0.0.1:${server.address.port}",
                    invitation = "invitation-token",
                    deviceName = "Pixel",
                    credentialPassword = "secret",
                ),
            )
            assertNotNull("the pairing request reached the server", received.get())
            assertEquals("Invitation invitation-token", received.get())
        } finally {
            server.stop(0)
        }
    }
}
