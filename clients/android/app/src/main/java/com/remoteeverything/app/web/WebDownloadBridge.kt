package com.remoteeverything.app.web

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import android.webkit.URLUtil
import android.webkit.WebView
import android.widget.Toast
import androidx.annotation.StringRes
import com.remoteeverything.app.R
import com.remoteeverything.core.api.belongsToGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * What a page's "download" becomes here. Three shapes arrive:
 *
 *  * http(s): fetched by the gateway's own TLS client — the application sits
 *    behind a device certificate, so the system download manager could never
 *    fetch it — with the WebView's cookies riding along, and landed in the
 *    public Downloads collection.
 *  * blob:/data:: no server is involved at all; the page holds the bytes.
 *    A small script streams them out through [blobBridge] in chunks.
 *
 * Anything saved is announced twice: a toast now, and a notification that names
 * the file, the folder it landed in and the tap that opens it — the receipt the
 * system downloader would have left. A failure says so rather than vanishing,
 * which is how a download that never started used to look.
 */
class WebDownloadBridge(
    context: Context,
    private val gatewayOrigin: String,
    private val clientProvider: () -> OkHttpClient?,
    private val cookieManager: CookieManager,
) {

    // The application, not the screen: a file that a person asked for keeps coming
    // after the page they started it from is gone.
    private val context: Context = context.applicationContext

    private val notice = WebDownloadNotice(context)

    /** A download from outside the gateway: system trust, no device certificate. */
    private val plainTransport: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(600, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    /** A download outlives the screen that started it: it ends with the process. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The JavascriptInterface the blob streaming script talks to. */
    val blobBridge = BlobBridge()

    private val blobs = java.util.concurrent.ConcurrentHashMap<String, BlobSink>()

    private class BlobSink(val name: String, val mime: String, val bytes: ByteArrayOutputStream)

    fun onDownload(view: WebView, url: String, userAgent: String, contentDisposition: String?, mimetype: String?) {
        when {
            url.startsWith("https://") || url.startsWith("http://") ->
                downloadHttp(url, userAgent, contentDisposition, mimetype)
            url.startsWith("blob:") ->
                downloadBlob(view, url, contentDisposition, mimetype)
            url.startsWith("data:") ->
                downloadData(url, contentDisposition, mimetype)
            else -> toast(R.string.web_download_failed)
        }
    }

    // --- http(s) --------------------------------------------------------------

    private fun downloadHttp(url: String, userAgent: String, contentDisposition: String?, mimetype: String?) {
        // A file from the gateway itself needs the device certificate to fetch; a
        // file from anywhere else — a CDN, an object store the page points at —
        // is fetched without it, because the credential is this gateway's and this
        // gateway's only, and a host outside it that asks for it is refused rather
        // than loaned it.
        val transport = if (belongsToGateway(gatewayOrigin, url)) {
            clientProvider() ?: run {
                toast(R.string.web_download_failed)
                return
            }
        } else {
            plainTransport
        }
        val client = transport.newBuilder().addNetworkInterceptor { chain ->
            val address = chain.request().url.toString()
            val request = chain.request().newBuilder().removeHeader("Cookie")
            cookieManager.getCookie(address)?.let { request.header("Cookie", it) }
            val response = chain.proceed(request.build())
            response.headers("Set-Cookie").forEach { cookieManager.setCookie(address, it) }
            response
        }.build()
        val name = fileName(url, contentDisposition, mimetype)
        scope.launch(Dispatchers.IO) {
            val saved = runCatching {
                val request = Request.Builder().url(url)
                    .header("User-Agent", userAgent)
                    .build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use null
                    val body = response.body
                    val mime = mimetype?.takeIf { it.isNotBlank() }
                        ?: body.contentType()?.let { "${it.type}/${it.subtype}" }
                        ?: "application/octet-stream"
                    writeToDownloads(name, mime) { out -> body.byteStream().copyTo(out) }?.let { Saved(it, mime) }
                }
            }.getOrNull()
            announce(name, saved)
        }
    }

    // --- blob: ----------------------------------------------------------------

    private fun downloadBlob(view: WebView, url: String, contentDisposition: String?, mimetype: String?) {
        val token = UUID.randomUUID().toString()
        val name = fileName(null, contentDisposition, mimetype)
        blobs[token] = BlobSink(name, mimetype ?: "application/octet-stream", ByteArrayOutputStream())
        // The blob only lives in the page's context, so the page itself reads
        // it and hands the bytes over in base64 chunks small enough for the
        // interface's string channel.
        val script = """
            (async () => {
              const b64 = (bytes) => {
                let s = '';
                for (let i = 0; i < bytes.length; i += 32768) {
                  s += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
                }
                return btoa(s);
              };
              try {
                const response = await fetch(${jsonString(url)});
                const blob = await response.blob();
                window.RemoteEverythingBlob.begin(${jsonString(token)}, blob.type || '');
                const reader = blob.stream().getReader();
                while (true) {
                  const { done, value } = await reader.read();
                  if (done) break;
                  window.RemoteEverythingBlob.append(${jsonString(token)}, b64(value));
                }
                window.RemoteEverythingBlob.end(${jsonString(token)});
              } catch (e) {
                window.RemoteEverythingBlob.fail(${jsonString(token)});
              }
            })();
        """.trimIndent()
        view.post { view.evaluateJavascript(script, null) }
    }

    inner class BlobBridge {
        @android.webkit.JavascriptInterface
        fun begin(token: String, mime: String) {
            blobs[token]?.let { blobs[token] = BlobSink(it.name, mime.ifBlank { it.mime }, it.bytes) }
        }

        @android.webkit.JavascriptInterface
        fun append(token: String, base64Chunk: String) {
            blobs[token]?.bytes?.write(android.util.Base64.decode(base64Chunk, android.util.Base64.DEFAULT))
        }

        @android.webkit.JavascriptInterface
        fun end(token: String) {
            val sink = blobs.remove(token) ?: return
            scope.launch(Dispatchers.IO) {
                val saved = runCatching {
                    writeToDownloads(sink.name, sink.mime) { out -> sink.bytes.writeTo(out) }
                        ?.let { Saved(it, sink.mime) }
                }.getOrNull()
                announce(sink.name, saved)
            }
        }

        @android.webkit.JavascriptInterface
        fun fail(token: String) {
            blobs.remove(token)
            toast(R.string.web_download_failed)
        }
    }

    // --- data: ------------------------------------------------------------------

    private fun downloadData(url: String, contentDisposition: String?, mimetype: String?) {
        val comma = url.indexOf(',')
        val header = if (comma >= 5) url.substring(5, comma) else ""
        if (comma < 0 || !header.endsWith(";base64")) {
            toast(R.string.web_download_failed)
            return
        }
        val mime = mimetype?.takeIf { it.isNotBlank() }
            ?: header.removeSuffix(";base64").ifBlank { "application/octet-stream" }
        val bytes = runCatching {
            android.util.Base64.decode(url.substring(comma + 1), android.util.Base64.DEFAULT)
        }.getOrNull() ?: run {
            toast(R.string.web_download_failed)
            return
        }
        val name = fileName(null, contentDisposition, mime)
        scope.launch(Dispatchers.IO) {
            val saved = runCatching {
                writeToDownloads(name, mime) { out -> out.write(bytes) }?.let { Saved(it, mime) }
            }.getOrNull()
            announce(name, saved)
        }
    }

    // --- shared -------------------------------------------------------------------

    /** A file that landed, with what it takes to open it again. */
    private class Saved(val uri: Uri, val mime: String)

    /**
     * The path is spelled the way the phone's own Downloads folder is spelled in
     * this language, because that is the folder the person will go looking in.
     */
    private fun announce(name: String, saved: Saved?) {
        if (saved == null) {
            toast(R.string.web_download_failed)
            return
        }
        notice.notify(name, saved.uri, saved.mime)
        toast(R.string.web_download_saved, "${context.getString(R.string.web_downloads)}/$name")
    }

    private fun writeToDownloads(name: String, mime: String, write: (java.io.OutputStream) -> Unit): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val resolver = context.contentResolver
        val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use(write) ?: throw java.io.IOException("no stream for $uri")
            uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    private fun fileName(url: String?, contentDisposition: String?, mimetype: String?): String {
        // The disposition is the name the page meant; a blob or data URL has no
        // path to guess from, so it comes first.
        val fromDisposition = contentDisposition?.let {
            Regex("""filename\*?=(?:UTF-8''|"?)([^";]+)""").find(it)?.groupValues?.get(1)?.let { raw -> Uri.decode(raw) }
        }
        val guessed = fromDisposition
            ?: url?.let { URLUtil.guessFileName(it, null, mimetype) }
            ?: "download"
        val withExtension = if (!guessed.contains('.') && !mimetype.isNullOrBlank()) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(mimetype)?.let { "$guessed.$it" } ?: guessed
        } else guessed
        // A name is a name, not a path: nothing the page says may climb out of Downloads.
                return withExtension.replace(Regex("[\\/:*?\"<>|\u0000-\u001F]"), "_").takeLast(120).ifBlank { "download" }
    }

    private fun jsonString(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""

    private fun toast(@StringRes message: Int, vararg args: Any) {
        val text = context.getString(message, *args)
        scope.launch {
            withContext(Dispatchers.Main) {
                Toast.makeText(context, text, Toast.LENGTH_SHORT).show()
            }
        }
    }
}
