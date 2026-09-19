package com.remoteeverything.core.diag

import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.NetworkError
import com.remoteeverything.core.model.UnreadableAnswer

/**
 * Why one connection is not answering.
 *
 * "Offline" is one word for three different situations: this phone has no
 * network, the gateway cannot be reached from where the phone stands, or the
 * gateway is answering and refusing. Only the last one is about the deployment;
 * the first is the phone's own business. Keeping the failure — not just a count
 * of failures — is what lets a screen and a report say which one it is.
 *
 * What the person does with this is copy it: an installation that cannot be
 * reached is a question for whoever runs the gateway, and the answer has to
 * travel. So the report carries what a reader needs and the phone happened to
 * see, in that order: what this client is, what it was talking to, what went
 * wrong, and what it knows about the network in between.
 */
data class LinkTrouble(
    val kind: Kind,
    val at: Long,
    val since: Long,
    val attempts: Int,
    val code: String? = null,
    val httpStatus: Int? = null,
    val detail: String? = null,
    val lastGoodAt: Long? = null,
) {
    enum class Kind { NO_NETWORK, UNREACHABLE, REFUSED, BAD_ANSWER, UNKNOWN }
}

/** One failed probe, kept so a report can show a run rather than a moment. */
data class LinkAttempt(val at: Long, val kind: LinkTrouble.Kind)

/** A classified failure: what it was, and whatever the wire said about it. */
data class LinkFailure(
    val kind: LinkTrouble.Kind,
    val code: String? = null,
    val httpStatus: Int? = null,
    val detail: String? = null,
)

/**
 * Everything a report says, gathered where the platform can answer it: the
 * version lines come from the build, the system line from the OS, the network
 * line from the platform's own idea of the network, and the rest from what the
 * client remembers about this connection.
 */
data class LinkReportInput(
    val appName: String,
    val client: String,
    val protocol: String,
    val system: String,
    val origin: String,
    val deviceName: String,
    val network: String,
    val machines: List<String>,
    val trouble: LinkTrouble,
    val attempts: List<LinkAttempt>,
    val time: (Long) -> String,
)

/** How many failed probes a report keeps: enough to show a pattern, not a log. */
const val LinkAttemptsKept = 4

/** Longest exception message a report carries; the rest is noise about noise. */
private const val DetailChars = 200

/**
 * Classifies one failure. `offline` is the platform's answer to "is there any
 * network this phone could be using at all": with nothing to send on, every
 * connection fails the same way, and that is worth saying before anything else.
 */
fun classifyFailure(failure: Throwable, offline: Boolean): LinkFailure = when {
    offline -> LinkFailure(LinkTrouble.Kind.NO_NETWORK, detail = describe(failure))
    failure is ClientError -> LinkFailure(
        LinkTrouble.Kind.REFUSED,
        // The enum is named after the wire code it carries (one code, one name),
        // so the name lowercased is what the gateway said.
        code = failure.code.name.lowercase(),
        httpStatus = failure.httpStatus,
        detail = describe(failure),
    )
    failure is UnreadableAnswer -> LinkFailure(LinkTrouble.Kind.BAD_ANSWER, detail = describe(failure))
    failure is NetworkError -> LinkFailure(
        LinkTrouble.Kind.UNREACHABLE,
        detail = describe(failure.cause ?: failure),
    )
    else -> LinkFailure(LinkTrouble.Kind.UNKNOWN, detail = describe(failure))
}

/**
 * The deepest cause, named. "network failure" says nothing a reader can use;
 * "SocketTimeoutException: timeout" says which hop stopped answering, and that
 * is the difference between a guess and a report.
 */
private fun describe(failure: Throwable): String {
    var deepest = failure
    while (true) {
        val next = deepest.cause ?: break
        if (next === deepest) break
        deepest = next
    }
    val message = deepest.message?.take(DetailChars)?.trim().orEmpty()
    return if (message.isEmpty()) deepest.javaClass.simpleName else "${deepest.javaClass.simpleName}: $message"
}

val LinkTrouble.Kind.messageKey: String
    get() = when (this) {
        LinkTrouble.Kind.NO_NETWORK -> MessageKeys.DIAG_CAUSE_NO_NETWORK
        LinkTrouble.Kind.UNREACHABLE -> MessageKeys.DIAG_CAUSE_UNREACHABLE
        LinkTrouble.Kind.REFUSED -> MessageKeys.DIAG_CAUSE_REFUSED
        LinkTrouble.Kind.BAD_ANSWER -> MessageKeys.DIAG_CAUSE_BAD_ANSWER
        LinkTrouble.Kind.UNKNOWN -> MessageKeys.DIAG_CAUSE_UNKNOWN
    }

/** What this kind of failure is called, in the language the app is in. */
fun LinkTrouble.Kind.phrase(say: (String, String?) -> String): String = say(messageKey, null)

/**
 * The report itself: one line per fact, each starting with a word for what the
 * line is — a screen-reader's shape, and the shape a person pastes into a
 * message without editing it first. `say` resolves a message key, with an
 * argument when the key takes one.
 */
fun buildLinkReport(input: LinkReportInput, say: (String, String?) -> String): String {
    val trouble = input.trouble
    val lines = mutableListOf<String>()

    lines += "${input.appName} · ${say(MessageKeys.DIAG_TITLE, null)}"
    lines += "${say(MessageKeys.DIAG_CLIENT, null)} ${input.client} · " +
        "${say(MessageKeys.SETTINGS_PROTOCOL_VERSION, null)} ${input.protocol}"
    lines += "${say(MessageKeys.DIAG_SYSTEM, null)} ${input.system}"
    lines += "${say(MessageKeys.DIAG_CONNECTION, null)} ${input.origin} · " +
        "${say(MessageKeys.DIAG_DEVICE_NAME, null)} ${input.deviceName}"

    // What is wrong, how long it has been wrong, and when it was last right:
    // three facts that together say whether this is new or a state of affairs.
    val state = buildList {
        add(trouble.kind.phrase(say))
        add(say(MessageKeys.DIAG_FAILURES, trouble.attempts.toString()))
        add(say(MessageKeys.DIAG_SINCE, input.time(trouble.since)))
        trouble.lastGoodAt?.let { add(say(MessageKeys.DIAG_LAST_ANSWER, input.time(it))) }
    }
    lines += "${say(MessageKeys.DIAG_STATE, null)} ${state.joinToString(" · ")}"

    // The wire's own words, when there were any: a code and a status are what a
    // gateway-side reader can look up, and the exception names the hop that failed.
    val cause = buildList {
        trouble.detail?.let { add(it) }
        trouble.httpStatus?.let { add("HTTP $it") }
        trouble.code?.let { add(it) }
    }
    lines += "${say(MessageKeys.DIAG_CAUSE, null)} ${cause.joinToString(" · ").ifEmpty { "—" }}"

    lines += "${say(MessageKeys.DIAG_NETWORK, null)} ${input.network}"
    val separator = if (
        input.appName.any { it.code in 0x4e00..0x9fff } ||
        say(MessageKeys.DIAG_TITLE, null).any { it.code in 0x4e00..0x9fff }
    ) "；" else "; "
    if (input.machines.isNotEmpty()) {
        lines += "${say(MessageKeys.DIAG_MACHINES, null)} ${input.machines.joinToString(separator)}"
    }
    if (input.attempts.isNotEmpty()) {
        val attempts = input.attempts.joinToString(separator) { "${input.time(it.at)} ${it.kind.phrase(say)}" }
        lines += "${say(MessageKeys.DIAG_ATTEMPTS, null)} $attempts"
    }
    return lines.joinToString("\n")
}
