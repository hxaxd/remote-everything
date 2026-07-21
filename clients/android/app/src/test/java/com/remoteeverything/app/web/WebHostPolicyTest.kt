package com.remoteeverything.app.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebHostPolicyTest {
    @Test
    fun externalIntentsUseAClosedSchemeAllowList() {
        assertTrue(WebHostPolicy.allowsExternalIntent("https://example.com/path"))
        assertTrue(WebHostPolicy.allowsExternalIntent("mailto:user@example.com"))
        assertTrue(WebHostPolicy.allowsExternalIntent("tel:+8613800138000"))
        assertFalse(WebHostPolicy.allowsExternalIntent("intent://scan/#Intent;scheme=zxing;end"))
        assertFalse(WebHostPolicy.allowsExternalIntent("file:///sdcard/private.txt"))
        assertFalse(WebHostPolicy.allowsExternalIntent("javascript:alert(1)"))
    }

    @Test
    fun fileSelectionOnlyAcceptsContentProviderUris() {
        assertTrue(WebHostPolicy.allowsSelectedFileScheme("content"))
        assertTrue(WebHostPolicy.allowsSelectedFileScheme("CONTENT"))
        assertFalse(WebHostPolicy.allowsSelectedFileScheme("file"))
        assertFalse(WebHostPolicy.allowsSelectedFileScheme("https"))
    }

    @Test
    fun downloadMetadataIsNormalized() {
        assertEquals("report_2026_.json", WebHostPolicy.sanitizeDownloadName(" report/2026?.json "))
        assertEquals("download", WebHostPolicy.sanitizeDownloadName("..."))
        assertEquals("text/plain", WebHostPolicy.normalizeMimeType("Text/Plain; charset=utf-8"))
        assertEquals("application/octet-stream", WebHostPolicy.normalizeMimeType("not a mime type"))
    }

    @Test
    fun blobPayloadLimitAccountsForBase64Expansion() {
        val maximumEncodedCharacters = ((WebHostPolicy.MAX_BLOB_BYTES + 2) / 3) * 4
        assertTrue(WebHostPolicy.base64PayloadLengthCanFit(maximumEncodedCharacters))
        assertFalse(WebHostPolicy.base64PayloadLengthCanFit(maximumEncodedCharacters + 1))
    }
}
