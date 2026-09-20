package com.remoteeverything.core.update

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateCheckerTest {

    private fun clientReturning(status: Int, body: String): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(
                Interceptor { chain ->
                    Response.Builder()
                        .request(chain.request())
                        .protocol(Protocol.HTTP_1_1)
                        .code(status)
                        .message(if (status == 200) "OK" else "Error")
                        .body(body.toResponseBody("application/json".toMediaType()))
                        .build()
                },
            )
            .build()

    private val validManifest = """
        {
          "schema": 1,
          "versionName": "1.2.0",
          "buildNumber": 20,
          "protocolVersion": 1,
          "minimumPlatforms": {
            "androidSdk": 26,
            "ios": "16.0",
            "harmonyApi": "12"
          }
        }
    """.trimIndent()

    @Test
    fun `returns available when remote build number is greater`() = runBlocking {
        val checker = UpdateChecker(manifestUrl = "https://example.com/release.json", client = clientReturning(200, validManifest))
        val result = checker.check(currentBuildNumber = 10, currentProtocolVersion = 1)
        assertTrue(result is UpdateChecker.Result.Available)
        val available = result as UpdateChecker.Result.Available
        assertEquals("1.2.0", available.versionName)
        assertEquals(20, available.buildNumber)
    }

    @Test
    fun `returns up to date when local build number is equal or greater`() = runBlocking {
        val checker = UpdateChecker(manifestUrl = "https://example.com/release.json", client = clientReturning(200, validManifest))
        val resultEqual = checker.check(currentBuildNumber = 20, currentProtocolVersion = 1)
        assertEquals(UpdateChecker.Result.UpToDate, resultEqual)

        val resultGreater = checker.check(currentBuildNumber = 25, currentProtocolVersion = 1)
        assertEquals(UpdateChecker.Result.UpToDate, resultGreater)
    }

    @Test
    fun `returns protocol changed when protocol version differs`() = runBlocking {
        val checker = UpdateChecker(manifestUrl = "https://example.com/release.json", client = clientReturning(200, validManifest))
        val result = checker.check(currentBuildNumber = 10, currentProtocolVersion = 2)
        assertTrue(result is UpdateChecker.Result.ProtocolChanged)
        assertEquals(1, (result as UpdateChecker.Result.ProtocolChanged).protocolVersion)
    }

    @Test
    fun `returns unreachable on HTTP failure or invalid payload`() = runBlocking {
        val checkerHttpError = UpdateChecker(manifestUrl = "https://example.com/release.json", client = clientReturning(404, "Not Found"))
        assertEquals(UpdateChecker.Result.Unreachable, checkerHttpError.check(20, 1))

        val checkerMalformed = UpdateChecker(manifestUrl = "https://example.com/release.json", client = clientReturning(200, "{ invalid json }"))
        assertEquals(UpdateChecker.Result.Unreachable, checkerMalformed.check(20, 1))
    }
}
