package com.remoteeverything.app.web

import java.net.URI

/** Pure policy helpers for capabilities exposed by the native WebView host. */
object WebHostPolicy {
    const val MAX_BLOB_BYTES = 16 * 1024 * 1024
    const val MAX_FILE_SELECTIONS = 100

    private val unsafeFileNameCharacters = Regex("[\\u0000-\\u001f\\u007f/\\\\:*?\"<>|]")
    private val validMimeType = Regex("^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$")
    private val externalSchemes = setOf("http", "https", "mailto", "tel")

    fun allowsExternalIntent(value: String): Boolean = runCatching {
        URI(value).scheme?.lowercase() in externalSchemes
    }.getOrDefault(false)

    fun allowsSelectedFileScheme(scheme: String?): Boolean = scheme.equals("content", ignoreCase = true)

    fun normalizeMimeType(value: String?): String {
        val candidate = value.orEmpty().substringBefore(';').trim().lowercase()
        return candidate.takeIf(validMimeType::matches) ?: "application/octet-stream"
    }

    fun sanitizeDownloadName(value: String?, fallback: String = "download"): String {
        val safeFallback = fallback.replace(unsafeFileNameCharacters, "_").trim(' ', '.').ifEmpty { "download" }
        val cleaned = value.orEmpty()
            .replace(unsafeFileNameCharacters, "_")
            .trim(' ', '.')
            .take(160)
            .trim(' ', '.')
        return cleaned.ifEmpty { safeFallback.take(160) }
    }

    fun base64PayloadCanFit(value: String): Boolean = base64PayloadLengthCanFit(value.length)

    internal fun base64PayloadLengthCanFit(length: Int): Boolean {
        val maximumEncodedCharacters = ((MAX_BLOB_BYTES + 2L) / 3L) * 4L
        return length.toLong() <= maximumEncodedCharacters
    }
}
