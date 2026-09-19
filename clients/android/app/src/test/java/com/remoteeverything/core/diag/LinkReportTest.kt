package com.remoteeverything.core.diag

import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.NetworkError
import com.remoteeverything.core.model.UnreadableAnswer
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a connection that will not answer is reported to be failing at, and what
 * the report says about it. The report is the one thing a person sends to
 * somebody else, so it is worth asserting on rather than eyeballing.
 */
class LinkReportTest {

    /** The keys themselves, so the test is about wiring and not about wording. */
    private val say: (String, String?) -> String = { key, arg -> if (arg == null) key else "$key=$arg" }

    private fun input(trouble: LinkTrouble, attempts: List<LinkAttempt> = emptyList()) = LinkReportInput(
        appName = "远程万物",
        client = "3.5.0 (28)",
        protocol = "1",
        system = "Android 16 (API 36) · OPPO PLG110",
        origin = "https://47-97-117-46.nip.io",
        deviceName = "PLG110",
        network = "wifi · internet ✓ · vpn ✗",
        machines = listOf("Windows-PC 本地 ✗ 隧道 ✗"),
        trouble = trouble,
        attempts = attempts,
        time = { at -> "T$at" },
    )

    // --- classification -------------------------------------------------------

    @Test
    fun `a refusal from the wire keeps its code and status`() {
        val failure = classifyFailure(ClientError(ErrorCode.UNAUTHORIZED, 401), offline = false)
        assertEquals(LinkTrouble.Kind.REFUSED, failure.kind)
        assertEquals("unauthorized", failure.code)
        assertEquals(401, failure.httpStatus)
    }

    @Test
    fun `a phone with nothing to send on says so before naming an exception`() {
        val failure = classifyFailure(NetworkError(UnknownHostException("gw.example.com")), offline = true)
        assertEquals(LinkTrouble.Kind.NO_NETWORK, failure.kind)
    }

    @Test
    fun `an unreachable gateway is named by its deepest cause`() {
        val failure = classifyFailure(NetworkError(SocketTimeoutException("timeout")), offline = false)
        assertEquals(LinkTrouble.Kind.UNREACHABLE, failure.kind)
        assertTrue(failure.detail!!, failure.detail!!.startsWith("SocketTimeoutException"))
    }

    @Test
    fun `the wrapper is not what is reported — the cause underneath it is`() {
        val failure = classifyFailure(NetworkError(IOException("outer", UnknownHostException("no such host"))), offline = false)
        assertTrue(failure.detail!!, failure.detail!!.startsWith("UnknownHostException"))
        assertTrue(failure.detail!!, failure.detail!!.contains("no such host"))
    }

    @Test
    fun `an answer that cannot be read is its own kind`() {
        assertEquals(
            LinkTrouble.Kind.BAD_ANSWER,
            classifyFailure(UnreadableAnswer("HTTP 502 without a refusal this client can read"), offline = false).kind,
        )
    }

    // --- the report -----------------------------------------------------------

    @Test
    fun `the report carries the connection, the cause, and the run of failures`() {
        val trouble = LinkTrouble(
            kind = LinkTrouble.Kind.UNREACHABLE,
            at = 500,
            since = 100,
            attempts = 4,
            detail = "SocketTimeoutException: timeout",
            lastGoodAt = 50,
        )
        val report = buildLinkReport(
            input(trouble, listOf(LinkAttempt(500, trouble.kind), LinkAttempt(400, trouble.kind))),
            say,
        )
        val lines = report.lines()
        assertEquals(
            listOf(
                "远程万物 · ${MessageKeys.DIAG_TITLE}",
                "${MessageKeys.DIAG_CLIENT} 3.5.0 (28) · ${MessageKeys.SETTINGS_PROTOCOL_VERSION} 1",
                "${MessageKeys.DIAG_SYSTEM} Android 16 (API 36) · OPPO PLG110",
                "${MessageKeys.DIAG_CONNECTION} https://47-97-117-46.nip.io · ${MessageKeys.DIAG_DEVICE_NAME} PLG110",
                "${MessageKeys.DIAG_STATE} ${MessageKeys.DIAG_CAUSE_UNREACHABLE} · " +
                    "${MessageKeys.DIAG_FAILURES}=4 · ${MessageKeys.DIAG_SINCE}=T100 · ${MessageKeys.DIAG_LAST_ANSWER}=T50",
                "${MessageKeys.DIAG_CAUSE} SocketTimeoutException: timeout",
                "${MessageKeys.DIAG_NETWORK} wifi · internet ✓ · vpn ✗",
                "${MessageKeys.DIAG_MACHINES} Windows-PC 本地 ✗ 隧道 ✗",
                "${MessageKeys.DIAG_ATTEMPTS} T500 ${MessageKeys.DIAG_CAUSE_UNREACHABLE}；T400 ${MessageKeys.DIAG_CAUSE_UNREACHABLE}",
            ),
            lines,
        )
    }

    @Test
    fun `a refusal reports the code and the status it came with`() {
        val trouble = LinkTrouble(
            kind = LinkTrouble.Kind.REFUSED,
            at = 1,
            since = 1,
            attempts = 1,
            code = "unauthorized",
            httpStatus = 401,
            detail = "ClientError: refused: UNAUTHORIZED",
        )
        val report = buildLinkReport(input(trouble), say)
        assertTrue(report, report.contains("${MessageKeys.DIAG_CAUSE} ClientError: refused: UNAUTHORIZED · HTTP 401 · unauthorized"))
    }

    @Test
    fun `a connection that never answered has no last-answer clause`() {
        val trouble = LinkTrouble(kind = LinkTrouble.Kind.NO_NETWORK, at = 1, since = 1, attempts = 2, detail = "offline")
        val report = buildLinkReport(input(trouble), say)
        assertTrue(report, report.contains(MessageKeys.DIAG_CAUSE_NO_NETWORK))
        assertTrue(report, !report.contains(MessageKeys.DIAG_LAST_ANSWER))
        assertTrue(report, !report.contains(MessageKeys.DIAG_ATTEMPTS))
    }

    @Test
    fun `an english report uses western semicolons for lists`() {
        val trouble = LinkTrouble(kind = LinkTrouble.Kind.UNREACHABLE, at = 200, since = 100, attempts = 2)
        val enInput = input(trouble, listOf(LinkAttempt(200, trouble.kind), LinkAttempt(100, trouble.kind))).copy(
            appName = "Remote Everything",
            machines = listOf("Machine A LAN ✓", "Machine B LAN ✗"),
        )
        val report = buildLinkReport(enInput, say)
        assertTrue(report, report.contains("${MessageKeys.DIAG_MACHINES} Machine A LAN ✓; Machine B LAN ✗"))
        assertTrue(report, report.contains("${MessageKeys.DIAG_ATTEMPTS} T200 ${MessageKeys.DIAG_CAUSE_UNREACHABLE}; T100 ${MessageKeys.DIAG_CAUSE_UNREACHABLE}"))
    }
}
