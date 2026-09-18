package com.remoteeverything.core.api

import com.remoteeverything.core.model.Identity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MergeTest {

    private fun identity(origin: String) = Identity(
        origin = origin,
        deviceName = "phone",
        certFingerprint = "f".repeat(64),
        credentialRef = "ref-$origin",
        serverPin = null,
        createdAtEpochMs = 0,
    )

    private val lan = identity("https://192.168.1.10")
    private val tunnel = identity("https://gw.example.com")
    private val nodeId = "a".repeat(64)

    @Test
    fun `the same node seen through two gateways merges into one row with two paths`() {
        val merged = mergeNodes(
            listOf(
                lan to NodesResponse(true, listOf(NodeDto(nodeId, "客厅电脑"))),
                tunnel to NodesResponse(true, listOf(NodeDto(nodeId, "客厅电脑"))),
            ),
        )
        assertEquals(1, merged.size)
        assertEquals(2, merged[0].paths.size)
        assertTrue(merged[0].paths[0].isPrivate)
        assertFalse(merged[0].paths[1].isPrivate)
    }

    @Test
    fun `distinct nodes stay distinct and keep first-seen order`() {
        val other = "b".repeat(64)
        val merged = mergeNodes(
            listOf(
                tunnel to NodesResponse(true, listOf(NodeDto(other, "B"), NodeDto(nodeId, "A"))),
            ),
        )
        assertEquals(listOf(other, nodeId), merged.map { it.id })
    }

    @Test
    fun `a node only one gateway serves has one path`() {
        val merged = mergeNodes(
            listOf(
                lan to NodesResponse(true, listOf(NodeDto(nodeId, "客厅电脑"))),
                tunnel to NodesResponse(true, emptyList()),
            ),
        )
        assertEquals(1, merged.size)
        assertEquals(1, merged[0].paths.size)
    }

    @Test
    fun `private origin detection covers RFC1918, link-local and loopback`() {
        assertTrue(isPrivateOrigin("https://10.0.0.1"))
        assertTrue(isPrivateOrigin("https://172.16.3.4:8443"))
        assertTrue(isPrivateOrigin("https://192.168.1.10"))
        assertTrue(isPrivateOrigin("https://169.254.1.1"))
        assertTrue(isPrivateOrigin("https://127.0.0.1"))
        assertFalse(isPrivateOrigin("https://gw.example.com"))
        assertFalse(isPrivateOrigin("https://172.32.0.1"))
        assertFalse(isPrivateOrigin("https://8.8.8.8"))
    }
}
