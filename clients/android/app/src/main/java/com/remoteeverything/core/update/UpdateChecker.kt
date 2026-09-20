package com.remoteeverything.core.update

import com.remoteeverything.core.json.Strict
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Update check against the published release manifest. Deliberately decoupled
 * from any gateway: an unpaired device can check too. The manifest is the
 * single source of truth all three platforms are versioned from.
 */
class UpdateChecker(
    private val manifestUrl: String = DEFAULT_MANIFEST_URL,
    private val client: OkHttpClient = defaultClient(),
) {

    @Serializable
    data class ReleaseManifest(
        val schema: Int,
        val versionName: String,
        val buildNumber: Int,
        val protocolVersion: Int,
        val minimumPlatforms: MinimumPlatforms,
    )

    @Serializable
    data class MinimumPlatforms(
        val androidSdk: Int,
        val ios: String,
        val harmonyApi: String,
    )

    sealed class Result {
        data object UpToDate : Result()
        data class Available(val versionName: String, val buildNumber: Int) : Result()
        data class ProtocolChanged(val protocolVersion: Int) : Result()
        data object Unreachable : Result()
    }

    private val json = Json { ignoreUnknownKeys = false }

    suspend fun check(currentBuildNumber: Int, currentProtocolVersion: Int): Result = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(manifestUrl).build()
        val body = try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext Result.Unreachable
                response.body.string()
            }
        } catch (e: Exception) {
            return@withContext Result.Unreachable
        }
        val manifest = try {
            json.decodeFromString<ReleaseManifest>(body)
        } catch (e: Exception) {
            return@withContext Result.Unreachable
        }
        val platforms = setOf(
            "androidSdk", "ios", "harmonyApi",
        )
        try {
            Strict.validateRelease(
                manifest.schema,
                manifest.versionName,
                manifest.buildNumber,
                manifest.protocolVersion,
                platforms,
            )
        } catch (e: Exception) {
            return@withContext Result.Unreachable
        }
        when {
            manifest.protocolVersion != currentProtocolVersion -> Result.ProtocolChanged(manifest.protocolVersion)
            manifest.buildNumber > currentBuildNumber -> Result.Available(manifest.versionName, manifest.buildNumber)
            else -> Result.UpToDate
        }
    }

    companion object {
        const val DEFAULT_MANIFEST_URL =
            "https://raw.githubusercontent.com/hxaxd/remote-everything/main/clients/release.json"

        private fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }
}
