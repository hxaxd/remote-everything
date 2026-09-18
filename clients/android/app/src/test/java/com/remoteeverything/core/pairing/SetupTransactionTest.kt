package com.remoteeverything.core.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The staging file is the whole memory of an interrupted pairing, so what it
 * must do is exactly: survive a restart, refuse to promise what has expired, and
 * never hand back something unreadable.
 */
class SetupTransactionTest {

    @get:Rule
    val folder = TemporaryFolder()

    private fun staged(expiresAt: Long) = StagedSetup(
        origin = "https://gw.example.com",
        nodeId = "a".repeat(64),
        nodeName = "客厅电脑",
        deviceName = "Pixel",
        certificateFingerprint = "b".repeat(64),
        serverPin = null,
        pendingExpiresAtEpochMs = expiresAt,
        createdAtEpochMs = 1_000,
    )

    @Test
    fun `a staged setup is read back exactly`() {
        val transaction = SetupTransaction(folder.newFile("staged.json"))
        transaction.stage(staged(expiresAt = 10_000))
        val loaded = transaction.load()
        assertNotNull(loaded)
        assertEquals("客厅电脑", loaded!!.nodeName)
        assertEquals("b".repeat(64), loaded.certificateFingerprint)
    }

    @Test
    fun `resuming inside the pending window keeps the setup`() {
        val transaction = SetupTransaction(folder.newFile("staged.json"))
        transaction.stage(staged(expiresAt = 10_000))
        assertNotNull(transaction.resume(nowEpochMs = 9_999))
        assertNotNull(transaction.load())
    }

    @Test
    fun `resuming after the window drops the setup`() {
        val transaction = SetupTransaction(folder.newFile("staged.json"))
        transaction.stage(staged(expiresAt = 10_000))
        assertNull(transaction.resume(nowEpochMs = 10_000))
        assertNull(transaction.load())
    }

    @Test
    fun `an unreadable file is no setup`() {
        val file = folder.newFile("staged.json")
        file.writeText("not json at all")
        val transaction = SetupTransaction(file)
        assertNull(transaction.load())
        assertNull(transaction.resume(nowEpochMs = 0))
    }

    @Test
    fun `clearing removes the file`() {
        val file = folder.newFile("staged.json")
        val transaction = SetupTransaction(file)
        transaction.stage(staged(expiresAt = 10_000))
        transaction.clear()
        assertTrue(!file.exists())
        assertNull(transaction.load())
    }
}
