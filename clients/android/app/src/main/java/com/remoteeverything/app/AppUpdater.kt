package com.remoteeverything.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection

sealed interface UpdateUiState {
    data object Idle : UpdateUiState
    data object Checking : UpdateUiState
    data class Current(val latestVersion: String, val currentIsNewer: Boolean) : UpdateUiState
    data class Available(val release: AppRelease, val installable: Boolean) : UpdateUiState
    data class Downloading(val release: AppRelease, val progress: Float) : UpdateUiState
    data class Ready(val release: AppRelease, val filePath: String) : UpdateUiState
    data class Error(val detail: String) : UpdateUiState
}

enum class InstallLaunchResult { INSTALLER_OPENED, PERMISSION_SETTINGS_OPENED }

/** 只接受项目 GitHub 正式 Release，并在安装前同时校验摘要、包身份、版本与固定签名。 */
class AppUpdater(private val context: Context) {
    fun checkLatest(): AppRelease {
        val body = downloadText(LATEST_RELEASE_API, 1024L * 1024L, apiRequest = true)
        return UpdateProtocol.parseLatestRelease(body)
    }

    fun isOfficialInstall(): Boolean = runCatching { installedSignerSha256() == OFFICIAL_SIGNER_SHA256 }.getOrDefault(false)

    fun downloadAndVerify(release: AppRelease, onProgress: (Float) -> Unit): String {
        require(isOfficialInstall()) { "当前安装的是开发签名版本，不能覆盖安装正式版" }
        val checksums = downloadText(release.checksums.url, release.checksums.size, apiRequest = false)
        release.checksums.digest?.let { expected ->
            require(MessageDigest.getInstance("SHA-256").digest(checksums.toByteArray(Charsets.UTF_8)).toHex() == expected) {
                "校验文件摘要不一致"
            }
        }
        val expected = UpdateProtocol.expectedApkSha256(checksums)
        release.apk.digest?.let { require(it == expected) { "发布页摘要与校验文件不一致" } }

        val directory = File(context.cacheDir, UPDATE_DIRECTORY).apply {
            require(exists() || mkdirs()) { "无法创建更新缓存" }
            require(isDirectory) { "更新缓存无效" }
        }
        directory.listFiles()?.forEach { candidate ->
            if (candidate.isFile && candidate.name.startsWith("remote-everything-") && candidate.name.endsWith(".apk")) candidate.delete()
        }
        val partial = File(directory, "remote-everything-${release.versionName}.apk.partial")
        val target = File(directory, "remote-everything-${release.versionName}.apk")
        partial.delete()
        target.delete()
        try {
            val actual = downloadFile(release.apk, partial, onProgress)
            require(actual == expected) { "安装包 SHA-256 校验失败" }
            verifyPackage(partial, release)
            Files.move(partial.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            return target.absolutePath
        } catch (error: Throwable) {
            partial.delete()
            target.delete()
            throw error
        }
    }

    @Suppress("DEPRECATION")
    fun launchInstaller(activityContext: Context, release: AppRelease, filePath: String): InstallLaunchResult {
        val directory = File(context.cacheDir, UPDATE_DIRECTORY).canonicalFile
        val file = File(filePath).canonicalFile
        require(file.parentFile == directory && file.isFile) { "待安装文件不存在" }
        verifyPackage(file, release)
        if (!activityContext.packageManager.canRequestPackageInstalls()) {
            activityContext.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, "package:${activityContext.packageName}".toUri()),
            )
            return InstallLaunchResult.PERMISSION_SETTINGS_OPENED
        }
        val uri = FileProvider.getUriForFile(activityContext, "${activityContext.packageName}.updates", file)
        activityContext.startActivity(
            Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                data = uri
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra(Intent.EXTRA_RETURN_RESULT, false)
            },
        )
        return InstallLaunchResult.INSTALLER_OPENED
    }

    private fun downloadText(url: String, maximum: Long, apiRequest: Boolean): String {
        val connection = open(url, apiRequest)
        try {
            require(connection.responseCode == HttpsURLConnection.HTTP_OK) { "下载服务返回 ${connection.responseCode}" }
            val declared = connection.contentLengthLong
            require(declared < 0 || declared <= maximum) { "下载内容超过限制" }
            val output = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= maximum) { "下载内容超过限制" }
                    output.write(buffer, 0, count)
                }
            }
            return output.toString(Charsets.UTF_8.name())
        } finally {
            connection.disconnect()
        }
    }

    private fun downloadFile(asset: ReleaseAsset, target: File, onProgress: (Float) -> Unit): String {
        val connection = open(asset.url, apiRequest = false)
        try {
            require(connection.responseCode == HttpsURLConnection.HTTP_OK) { "安装包下载返回 ${connection.responseCode}" }
            val declared = connection.contentLengthLong
            require(declared < 0 || declared == asset.size) { "安装包大小与发布信息不一致" }
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            FileOutputStream(target).use { output ->
                connection.inputStream.use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= asset.size) { "安装包大小超过发布信息" }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        onProgress((total.toDouble() / asset.size.toDouble()).toFloat().coerceIn(0f, 1f))
                    }
                    output.fd.sync()
                }
            }
            require(total == asset.size) { "安装包下载不完整" }
            return digest.digest().toHex()
        } finally {
            connection.disconnect()
        }
    }

    private fun open(initialUrl: String, apiRequest: Boolean): HttpsURLConnection {
        var current = initialUrl
        repeat(MAX_REDIRECTS + 1) { redirect ->
            validateNetworkUrl(current, apiRequest)
            val connection = URL(current).openConnection() as HttpsURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 10_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Accept", if (apiRequest) "application/vnd.github+json" else "application/octet-stream")
            connection.setRequestProperty("User-Agent", "RemoteEverything/${BuildConfig.VERSION_NAME}")
            if (apiRequest) connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            val status = connection.responseCode
            if (status !in REDIRECT_CODES) return connection
            require(redirect < MAX_REDIRECTS) { "下载重定向过多" }
            val location = connection.getHeaderField("Location") ?: error("下载重定向缺少地址")
            current = URL(URL(current), location).toString()
            connection.disconnect()
        }
        error("下载重定向过多")
    }

    private fun validateNetworkUrl(value: String, apiRequest: Boolean) {
        val url = URL(value)
        require(url.protocol == "https" && url.userInfo == null && url.ref == null) { "更新地址不安全" }
        val allowed = if (apiRequest) {
            url.host == "api.github.com" && url.path == "/repos/hxaxd/remote-everything/releases/latest"
        } else {
            url.host in ASSET_HOSTS
        }
        require(allowed) { "更新地址不属于可信来源" }
    }

    private fun verifyPackage(file: File, release: AppRelease) {
        require(file.length() == release.apk.size) { "安装包文件大小无效" }
        val info = archivePackageInfo(file) ?: error("无法读取安装包信息")
        require(info.packageName == context.packageName) { "安装包应用标识不匹配" }
        require(info.versionName == release.versionName && info.longVersionCode > BuildConfig.VERSION_CODE) { "安装包版本无效" }
        require(packageSignerSha256(info) == OFFICIAL_SIGNER_SHA256) { "安装包签名不是项目正式签名" }
        require(installedSignerSha256() == OFFICIAL_SIGNER_SHA256) { "当前安装签名与正式版不一致" }
    }

    private fun installedSignerSha256(): String = packageSignerSha256(installedPackageInfo())

    @Suppress("DEPRECATION")
    private fun installedPackageInfo(): PackageInfo = if (Build.VERSION.SDK_INT >= 33) {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
    } else {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
    }

    @Suppress("DEPRECATION")
    private fun archivePackageInfo(file: File): PackageInfo? = if (Build.VERSION.SDK_INT >= 33) {
        context.packageManager.getPackageArchiveInfo(file.absolutePath, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
    } else {
        context.packageManager.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES)
    }

    private fun packageSignerSha256(info: PackageInfo): String {
        val signing = requireNotNull(info.signingInfo) { "安装包没有签名信息" }
        val signers = signing.apkContentsSigners
        require(signers.size == 1) { "安装包签名数量无效" }
        return MessageDigest.getInstance("SHA-256").digest(signers.single().toByteArray()).toHex()
    }

    private fun ByteArray.toHex(): String = joinToString("") { byte -> "%02x".format(byte) }

    private companion object {
        const val LATEST_RELEASE_API = "https://api.github.com/repos/hxaxd/remote-everything/releases/latest"
        const val UPDATE_DIRECTORY = "updates"
        const val MAX_REDIRECTS = 5
        const val OFFICIAL_SIGNER_SHA256 = "0fa51efa8c5ed1e1a6265dbcbf863bd3996619109430860b564a7cc4f73fca9e"
        val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        val ASSET_HOSTS = setOf("github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com")
    }
}
