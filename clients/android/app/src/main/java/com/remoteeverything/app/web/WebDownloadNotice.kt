package com.remoteeverything.app.web

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.remoteeverything.app.R

/**
 * What a saved file leaves behind: the phone's own kind of receipt.
 *
 * The system downloader is not the one fetching here — the application sits behind
 * a device certificate, so only this client's TLS client can read it — but the
 * person still expects what the system downloader gives: something in the shade
 * that names the file, says where it went, and opens it. [notify] is that, and it
 * is the only place the host's downloads are announced.
 */
class WebDownloadNotice(private val context: Context) {

    private val manager = NotificationManagerCompat.from(context)

    /** One entry per saved file, each with its own id so none replaces another. */
    fun notify(name: String, uri: Uri, mime: String) {
        ensureChannel()
        val request = name.hashCode()
        val open = PendingIntent.getActivity(context, request, openIntent(uri, mime), PendingIntentFlags)
        val notification = NotificationCompat.Builder(context, ChannelId)
            .setSmallIcon(R.drawable.ic_notification_download)
            .setContentTitle(name)
            .setContentText(context.getString(R.string.web_download_saved, displayedPath(name)))
            .setContentIntent(open)
            .addAction(0, context.getString(R.string.web_download_open), open)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        runCatching { manager.notify(request, notification) }
    }

    /** Where the file actually is, named the way the phone's own folder is named. */
    private fun displayedPath(name: String): String =
        "${context.getString(R.string.web_downloads)}/$name"

    /**
     * The file is ours and the viewer is not: the URI travels with a read grant,
     * which is what lets the gallery or the document viewer open it.
     */
    private fun openIntent(uri: Uri, mime: String): Intent =
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun ensureChannel() {
        val channel = NotificationChannel(
            ChannelId,
            context.getString(R.string.web_downloads),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        manager.createNotificationChannel(channel)
    }

    private companion object {
        const val ChannelId = "downloads"
        const val PendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }
}
