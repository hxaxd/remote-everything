package com.remoteeverything.behavior

import com.remoteeverything.app.NodesController
import com.remoteeverything.core.api.ApiClient
import com.remoteeverything.core.api.CatalogOutcome
import com.remoteeverything.core.api.CatalogResponse
import com.remoteeverything.core.api.ControlResponse
import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.api.NodeDto
import com.remoteeverything.core.api.PairRequest
import com.remoteeverything.core.api.PairingResponse
import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.Path
import com.remoteeverything.core.pathselect.PathSelector
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The behaviour all three clients share, asserted against the fixtures in
 * clients/behavior: the same refusal is the same name, the same two gateways
 * are one row, the same paths choose the same one, and the same catalog answer
 * is the same screen. A client that stops agreeing with these fails here —
 * which is the only way "the three clients behave alike" stays true.
 */
class BehaviorFixturesTest {

    // A fixture is a description, not a wire message: it is allowed to carry
    // prose the decoders here do not use. The strictness that matters — the
    // wire's own — is asserted where the wire is decoded (DtoTest and the
    // production decoders).
    private val json = Json { ignoreUnknownKeys = true }
    private val fixtures = File("../../behavior/fixtures")

    private fun fixture(name: String): String {
        val file = File(fixtures, name)
        assertTrue("fixture ${file.path} is missing", file.isFile)
        return file.readText(Charsets.UTF_8)
    }

    // --- errors.json ---------------------------------------------------------

    @Serializable
    private class ErrorFixture(val cases: List<ErrorCase>)

    @Serializable
    private class ErrorCase(val code: String, val key: String)

    @Test
    fun `every refusal is the name the contract gives it`() {
        val cases = json.decodeFromString(ErrorFixture.serializer(), fixture("errors.json")).cases
        assertEquals(19, cases.size)
        for (case in cases) {
            val code = json.decodeFromString(ErrorCode.serializer(), "\"${case.code}\"")
            assertEquals(case.code, case.key, MessageKeys.forError(code))
        }
    }

    // --- nodes.json ----------------------------------------------------------

    @Serializable
    private class NodesFixture(
        val identities: List<IdentityFixture>,
        val answers: List<AnswerFixture>,
        val expected: ExpectedFixture,
    )

    @Serializable
    private class IdentityFixture(val origin: String, val isPrivate: Boolean)

    @Serializable
    private class AnswerFixture(
        val origin: String,
        val ok: Boolean,
        val reachable: Boolean,
        val latencyMs: Long?,
        val nodes: List<NodeDto>,
    )

    @Serializable
    private class ExpectedFixture(val nodes: List<ExpectedNode>)

    @Serializable
    private class ExpectedNode(
        val id: String,
        val name: String,
        val pathCount: Int,
        val chosenOrigin: String,
        val chosenIsPrivate: Boolean,
    )

    @Test
    fun `the same machine through two gateways is one row with the LAN path chosen`() = runBlocking {
        val fixture = json.decodeFromString(NodesFixture.serializer(), fixture("nodes.json"))
        val identities = fixture.identities.map { identity ->
            Identity(
                origin = identity.origin,
                deviceName = "Pixel",
                certFingerprint = "f".repeat(64),
                credentialRef = identity.origin,
                serverPin = null,
                createdAtEpochMs = 0,
            )
        }
        val answers = fixture.answers.associate { answer ->
            identities.first { it.origin == answer.origin } to NodesResponse(ok = answer.ok, nodes = answer.nodes)
        }
        val controller = NodesController(clientFactory = { identity -> FakeClient(answers.getValue(identity)) })
        val merged = controller.refresh(identities, "wifi-1")
        assertEquals(fixture.expected.nodes.size, merged.size)
        for (expected in fixture.expected.nodes) {
            val node = merged.first { it.id == expected.id }
            assertEquals(expected.name, node.name)
            assertEquals(expected.pathCount, node.paths.size)
            val chosen = controller.choosePath(node, "wifi-1")
            assertEquals(expected.chosenOrigin, chosen?.origin)
            assertEquals(expected.chosenIsPrivate, chosen?.isPrivate)
        }
    }

    // --- paths.json ----------------------------------------------------------

    @Serializable
    private class PathsFixture(val cases: List<PathCase>)

    @Serializable
    private class PathCase(val name: String, val paths: List<PathFixture>, val chosen: String?)

    @Serializable
    private class PathFixture(
        val origin: String,
        val reachable: Boolean? = null,
        val latencyMs: Long? = null,
        val isPrivate: Boolean,
    )

    @Test
    fun `the chosen path is the same everywhere`() {
        val cases = json.decodeFromString(PathsFixture.serializer(), fixture("paths.json")).cases
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val paths = case.paths.map { path ->
                Path(
                    origin = path.origin,
                    reachable = path.reachable,
                    latencyMs = path.latencyMs,
                    isPrivate = path.isPrivate,
                )
            }
            val chosen = PathSelector.choose(paths)
            if (case.chosen == null) {
                assertNull(case.name, chosen)
            } else {
                assertEquals(case.name, case.chosen, chosen?.origin)
            }
        }
    }

    // --- cadence.json --------------------------------------------------------

    @Serializable
    private class CadenceFixture(
        val nodeRefreshMs: Long,
        val catalogRefreshMs: Long,
        val controlPollMs: Long,
        val controlPollFactor: Double,
        val controlPollCeilingMs: Long,
        val controlPollTimeoutMs: Long,
        val approvalPollMs: Long,
        val approvalPollTimeoutMs: Long,
        val pendingFallbackMs: Long,
        val probeTimeoutMs: Long,
        val requestTimeoutMs: Long,
    )

    @Test
    fun `the patience is the one all three clients share`() {
        val fixture = json.decodeFromString(CadenceFixture.serializer(), fixture("cadence.json"))
        assertEquals("nodeRefreshMs", fixture.nodeRefreshMs, Cadence.nodeRefreshMs)
        assertEquals("catalogRefreshMs", fixture.catalogRefreshMs, Cadence.catalogRefreshMs)
        assertEquals("controlPollMs", fixture.controlPollMs, Cadence.controlPollMs)
        assertEquals("controlPollFactor", fixture.controlPollFactor, Cadence.controlPollFactor, 0.0001)
        assertEquals("controlPollCeilingMs", fixture.controlPollCeilingMs, Cadence.controlPollCeilingMs)
        assertEquals("controlPollTimeoutMs", fixture.controlPollTimeoutMs, Cadence.controlPollTimeoutMs)
        assertEquals("approvalPollMs", fixture.approvalPollMs, Cadence.approvalPollMs)
        assertEquals("approvalPollTimeoutMs", fixture.approvalPollTimeoutMs, Cadence.approvalPollTimeoutMs)
        assertEquals("pendingFallbackMs", fixture.pendingFallbackMs, Cadence.pendingFallbackMs)
        assertEquals("probeTimeoutMs", fixture.probeTimeoutMs, Cadence.probeTimeoutMs)
        assertEquals("requestTimeoutMs", fixture.requestTimeoutMs, Cadence.requestTimeoutMs)
    }

    // --- catalog.json --------------------------------------------------------

    @Serializable
    private class CatalogFixture(val cases: List<CatalogCase>)

    @Serializable
    private class CatalogCase(
        val name: String,
        val answer: CatalogResponse,
        val screen: String,
        val apps: List<ExpectedApp> = emptyList(),
    )

    @Serializable
    private class ExpectedApp(val id: String, val key: String, val fragment: String)

    @Test
    fun `a catalog answer is the screen the contract gives it`() {
        val cases = json.decodeFromString(CatalogFixture.serializer(), fixture("catalog.json")).cases
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            when (val screen = CatalogOutcome.forAnswer(case.answer)) {
                is CatalogOutcome.Apps -> {
                    assertEquals(case.name, "apps", case.screen)
                    assertEquals(case.name, case.apps.size, screen.apps.size)
                    for (expected in case.apps) {
                        val app = screen.apps.first { it.id == expected.id }
                        assertEquals(case.name, expected.key, MessageKeys.forAppState(app.code))
                        assertEquals(case.name, expected.fragment, app.launchFragment)
                    }
                }
                CatalogOutcome.Offline -> assertEquals(case.name, "node.offline", case.screen)
                CatalogOutcome.Unauthorized -> assertEquals(case.name, "error.node_gone", case.screen)
                CatalogOutcome.GatewayTrouble -> assertEquals(case.name, "pair.gateway_trouble", case.screen)
            }
        }
    }

    // --- message-keys.json ---------------------------------------------------

    private fun fixtureKeys(): Set<String> =
        json.decodeFromString<JsonArray>(fixture("message-keys.json")).map { it.jsonPrimitive.content }.toSet()

    @Test
    fun `the vocabulary is the one the fixture names`() {
        val constants = MessageKeys::class.java.declaredFields
            .filter { it.type == String::class.java }
            .map { it.get(null) as String }
            .toSet()
        assertEquals("message-keys.json", fixtureKeys(), constants)
    }

    @Test
    fun `every key is a resource in both languages`() {
        val canonical = fixtureKeys().map { it.replace('.', '_') }.toSet()
        val names = { path: String ->
            Regex("name=\"([a-z0-9_]+)\"")
                .findAll(File(path).readText(Charsets.UTF_8))
                .map { it.groupValues[1] }
                .toSet()
        }
        val english = names("src/main/res/values/strings.xml")
        val chinese = names("src/main/res/values-zh/strings.xml")
        assertEquals("the two languages carry the same keys", english, chinese)
        assertEquals("values/strings.xml", canonical, english)
    }
}

/** An /nodes answer on tap, for the behaviour test to drive the production controller. */
private class FakeClient(private val nodes: NodesResponse) : ApiClient {
    override val origin: String = "fake"
    override suspend fun pair(request: PairRequest): PairingResponse = error("unused by the behaviour test")
    override suspend fun activate(nodeId: String): CatalogResponse = error("unused by the behaviour test")
    override suspend fun nodes(): NodesResponse = nodes
    override suspend fun catalog(nodeId: String): CatalogResponse = error("unused by the behaviour test")
    override suspend fun status(nodeId: String, appId: String): ControlResponse = error("unused by the behaviour test")
    override suspend fun start(nodeId: String, appId: String): ControlResponse = error("unused by the behaviour test")
    override suspend fun stop(nodeId: String, appId: String): ControlResponse = error("unused by the behaviour test")
    override suspend fun open(nodeId: String, appId: String): String = error("unused by the behaviour test")
}
