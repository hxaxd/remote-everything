package com.remoteeverything.core.api

import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.identity.credentialAlias
import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.NetworkError
import com.remoteeverything.core.model.ServerPin
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.X509ExtendedTrustManager
import kotlin.coroutines.resumeWithException

/**
 * The wire as OkHttp speaks it: strict decoding, real cancellation, no redirect
 * following, and a TLS context built from exactly this origin's credential and
 * pin.
 */
internal class OkHttpGatewayClient(
    override val origin: String,
    private val material: Pkcs12.Material?,
    serverPin: ServerPin?,
) : GatewayClient {

    private val json = Json { ignoreUnknownKeys = false }
    private val client: OkHttpClient = gatewayOkHttpClient(origin, material, serverPin, followRedirects = false, readTimeoutSeconds = 10)

    private class Answer(val status: Int, val body: String, val location: String?)

    private suspend fun call(
        method: String,
        path: String,
        nodeId: String?,
        body: String?,
        readTimeout: Long,
        headers: Map<String, String> = emptyMap(),
    ): Answer {
        val url = origin.toHttpUrl().newBuilder().encodedPath(path).build()
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .apply { if (nodeId != null) header(NodeHeader, nodeId) }
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .method(method, body?.toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()
        val call = client.newCall(request)
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            // The per-call budget is armed before the call is queued: set after
            // enqueue it races the dispatcher and may never apply, and a probe
            // meant to cost two seconds silently costs the client's ten.
            call.timeout().timeout(readTimeout, TimeUnit.MILLISECONDS)
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(NetworkError(e))
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use { answered ->
                        val text = try {
                            answered.body.string()
                        } catch (e: Exception) {
                            ""
                        }
                        if (continuation.isActive) {
                            continuation.resumeWith(
                                Result.success(Answer(answered.code, text, answered.header("Location"))),
                            )
                        }
                    }
                }
            })
        }
    }

    private fun refusal(status: Int, body: String): Nothing {
        val error = try {
            json.decodeFromString(ErrorResponse.serializer(), body)
        } catch (e: Exception) {
            throw NetworkError(IOException("the gateway answered $status"))
        }
        Wire.validateError(error)
        throw ClientError(error.code, status)
    }

    private fun <T> decoded(status: Int, body: String, decode: (String) -> T): T {
        if (status !in 200..299) refusal(status, body)
        return try {
            decode(body)
        } catch (e: Exception) {
            // A body this client cannot read is a body it does not understand, and
            // the protocol says an implementation rejects that rather than guessing.
            throw NetworkError(IOException("the gateway answered a body this client does not understand"))
        }
    }

    override suspend fun pair(request: PairRequest): PairingResponse {
        val body = json.encodeToString(
            PairingRequest.serializer(),
            PairingRequest(device_name = request.deviceName, credential_password = request.credentialPassword),
        )
        // Pairing is the one request a gateway accepts without a credential: the
        // invitation is what it carries instead, in the header the server reads it from.
        val answer = call(
            "POST", PairPath, nodeId = null, body = body, readTimeout = ReadTimeoutMs,
            headers = mapOf("Authorization" to "Invitation ${request.invitation}"),
        )
        return decoded(answer.status, answer.body) {
            json.decodeFromString(PairingResponse.serializer(), it).also { response -> Wire.validatePairing(response) }
        }
    }

    override suspend fun activate(nodeId: String): CatalogResponse {
        val answer = call("POST", ActivatePath, nodeId = nodeId, body = "", readTimeout = ReadTimeoutMs)
        if (answer.status == 202) {
            throw ClientError(ErrorCode.APPROVAL_PENDING, answer.status)
        }
        return decoded(answer.status, answer.body) {
            json.decodeFromString(CatalogResponse.serializer(), it).also { response ->
                Wire.validateCatalog(response)
                // activation.schema.json: the catalog an activation answers with is
                // always the connected, ready one — a device is never activated
                // against a node that is not there. The apps endpoint may answer
                // offline; activation may not, and refusing it here is what keeps
                // an unreachable node from being shown as usable.
                require(response.computer_connected && response.code == CatalogCode.READY) {
                    "an activation is not the connected, ready catalog the schema requires"
                }
            }
        }
    }

    override suspend fun nodes(): NodesResponse {
        val answer = call("GET", NodesPath, nodeId = null, body = null, readTimeout = ProbeTimeoutMs)
        return decoded(answer.status, answer.body) {
            json.decodeFromString(NodesResponse.serializer(), it).also { response -> Wire.validateNodes(response) }
        }
    }

    override suspend fun catalog(nodeId: String): CatalogResponse {
        val answer = call("GET", CatalogPath, nodeId = nodeId, body = null, readTimeout = ReadTimeoutMs)
        return decoded(answer.status, answer.body) {
            json.decodeFromString(CatalogResponse.serializer(), it).also { response -> Wire.validateCatalog(response) }
        }
    }

    override suspend fun status(nodeId: String, appId: String): ControlResponse =
        control("GET", "/__remote_everything/apps/$appId/status", nodeId, ReadTimeoutMs)

    override suspend fun start(nodeId: String, appId: String): ControlResponse =
        control("POST", "/__remote_everything/apps/$appId/start", nodeId, ReadTimeoutMs)

    override suspend fun stop(nodeId: String, appId: String): ControlResponse =
        control("POST", "/__remote_everything/apps/$appId/stop", nodeId, StopReadTimeoutMs)

    private suspend fun control(method: String, path: String, nodeId: String, readTimeout: Long): ControlResponse {
        val answer = call(method, path, nodeId = nodeId, body = if (method == "POST") "" else null, readTimeout = readTimeout)
        return decoded(answer.status, answer.body) {
            json.decodeFromString(ControlResponse.serializer(), it).also { response -> Wire.validateControl(response) }
        }
    }

    override suspend fun open(nodeId: String, appId: String): String {
        val answer = call("GET", "/__remote_everything/open/$appId", nodeId = nodeId, body = null, readTimeout = ReadTimeoutMs)
        if (answer.status !in 300..399 || answer.location.isNullOrBlank()) {
            refusal(answer.status, answer.body)
        }
        return answer.location
    }

    companion object {
        /** The header a request names its node with; the node list is the one that carries none. */
        const val NodeHeader = "X-Remote-Everything-Node"

        private const val PairPath = "/__remote_everything_pair"
        private const val ActivatePath = "/__remote_everything_activate"
        private const val NodesPath = "/__remote_everything/nodes"
        private const val CatalogPath = "/__remote_everything/apps"
        private const val ReadTimeoutMs = Cadence.requestTimeoutMs

        /** The node list is also the probe, so it is given the patience of one. */
        private const val ProbeTimeoutMs = Cadence.probeTimeoutMs

        /** A stop asks the node to stop an application; the gateway waits up to 20 s for that. */
        private const val StopReadTimeoutMs = 30_000L
    }
}

/**
 * One TLS posture, two callers: the protocol client speaks its requests
 * through it, and an application download rides it bare — same credential,
 * same pin, with redirects followed and a reader's patience a file deserves
 * rather than a probe's.
 */
internal fun gatewayOkHttpClient(
    origin: String,
    material: Pkcs12.Material?,
    serverPin: ServerPin?,
    followRedirects: Boolean,
    readTimeoutSeconds: Long,
): OkHttpClient {
    val trust: X509ExtendedTrustManager =
        if (serverPin != null) PinnedTrustManager(serverPin) else systemTrustManager()
    val builder = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(readTimeoutSeconds, TimeUnit.SECONDS)
        .followRedirects(followRedirects)
        .followSslRedirects(followRedirects)
        .retryOnConnectionFailure(false)
    if (material != null || serverPin != null) {
        val keyManagers = material?.let { arrayOf<KeyManager>(IdentityKeyManager(credentialAlias(origin), it)) }
        val context = SSLContext.getInstance("TLS")
        context.init(keyManagers, arrayOf(trust), SecureRandom())
        builder.sslSocketFactory(context.socketFactory, trust)
    }
    return builder.build()
}
