package com.remoteeverything.core.api

import com.remoteeverything.core.json.Strict
import com.remoteeverything.core.update.UpdateChecker
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The wire-strictness cases all three clients run, from
 * clients/behavior/fixtures/wire-cases.json: every case goes through the
 * production strict decoder and the same validation the gateway client uses, so
 * a rule iOS enforces and Android does not shows up here as a failure, and vice
 * versa. The fixture is the arbiter; this test is only its runner.
 */
class WireCasesTest {

    private val json = Json { ignoreUnknownKeys = false }
    private val fixtures = File("../../behavior/fixtures")

    @Serializable
    private data class WireCases(val cases: List<WireCase>)

    @Serializable
    private data class WireCase(
        val name: String,
        val kind: String,
        val payload: JsonElement,
        val expect: String,
        val reason: String,
    )

    @Test
    fun `the wire is as strict here as the fixture says`() {
        val document = json.decodeFromString(
            WireCases.serializer(),
            File(fixtures, "wire-cases.json").readText(Charsets.UTF_8),
        )
        assertTrue(document.cases.isNotEmpty())
        var exercised = 0
        for (case in document.cases) {
            val accepted = runCatching { decode(case.kind, case.payload.toString()) }.isSuccess
            when (case.expect) {
                "accept" -> assertTrue("${case.name}: ${case.reason}", accepted)
                "reject" -> assertFalse("${case.name}: ${case.reason}", accepted)
                else -> error("unknown expectation in ${case.name}")
            }
            exercised += 1
        }
        assertTrue("expected at least the fixture's cases to run", exercised == document.cases.size)
    }

    private fun decode(kind: String, text: String) {
        when (kind) {
            "nodes" -> json.decodeFromString(NodesResponse.serializer(), text).also { Wire.validateNodes(it) }
            "catalog", "apps" -> json.decodeFromString(CatalogResponse.serializer(), text).also { Wire.validateCatalog(it) }
            "control" -> json.decodeFromString(ControlResponse.serializer(), text).also { Wire.validateControl(it) }
            "pairing" -> json.decodeFromString(PairingResponse.serializer(), text).also { Wire.validatePairing(it) }
            "error" -> json.decodeFromString(ErrorResponse.serializer(), text).also { Wire.validateError(it) }
            "activation" -> decodeActivation(text)
            "release" -> decodeRelease(text)
            else -> error("unknown wire kind $kind")
        }
    }

    /** An activation is the connected catalog, or a refusal — never the offline catalog. */
    private fun decodeActivation(text: String) {
        val asCatalog = runCatching {
            json.decodeFromString(CatalogResponse.serializer(), text).also { Wire.validateCatalog(it) }
        }
        if (asCatalog.isSuccess) return
        json.decodeFromString(ErrorResponse.serializer(), text).also { Wire.validateError(it) }
    }

    private fun decodeRelease(text: String) {
        val manifest = json.decodeFromString(UpdateChecker.ReleaseManifest.serializer(), text)
        Strict.validateRelease(
            manifest.schema,
            manifest.versionName,
            manifest.buildNumber,
            manifest.protocolVersion,
            setOf("androidSdk", "ios", "harmonyApi"),
        )
    }
}
