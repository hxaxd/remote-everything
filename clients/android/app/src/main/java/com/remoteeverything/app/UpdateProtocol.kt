package com.remoteeverything.app

import org.json.JSONObject
import java.net.URI

const val PROJECT_URL = "https://github.com/hxaxd/remote-everything"

data class ReleaseAsset(
    val name: String,
    val url: String,
    val size: Long,
    val digest: String?,
)

data class AppRelease(
    val versionName: String,
    val tagName: String,
    val pageUrl: String,
    val apk: ReleaseAsset,
    val checksums: ReleaseAsset,
)

/** GitHub Release 响应与版本号的纯数据契约，独立于 Android，便于单元测试。 */
object UpdateProtocol {
    private const val APK_NAME = "app-release.apk"
    private const val CHECKSUMS_NAME = "SHA256SUMS"
    private const val MAX_APK_BYTES = 300L * 1024L * 1024L
    private const val MAX_CHECKSUM_BYTES = 1024L * 1024L
    private val versionPattern = Regex("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
    private val sha256Pattern = Regex("^[a-f0-9]{64}$")

    fun parseLatestRelease(body: String): AppRelease {
        val value = JSONObject(body)
        require(!value.optBoolean("draft", true) && !value.optBoolean("prerelease", true)) { "最新发布版不可安装" }
        val tag = value.getString("tag_name")
        val version = canonicalVersion(tag)
        require(tag == "v$version") { "发布标签格式无效" }
        val pageUrl = value.getString("html_url")
        require(pageUrl == "$PROJECT_URL/releases/tag/$tag") { "发布页面地址无效" }

        val assets = value.getJSONArray("assets")
        var apk: ReleaseAsset? = null
        var checksums: ReleaseAsset? = null
        for (index in 0 until assets.length()) {
            val raw = assets.getJSONObject(index)
            val name = raw.getString("name")
            if (name != APK_NAME && name != CHECKSUMS_NAME) continue
            require(raw.getString("state") == "uploaded") { "发布资产尚未就绪" }
            val size = raw.getLong("size")
            val maximum = if (name == APK_NAME) MAX_APK_BYTES else MAX_CHECKSUM_BYTES
            require(size in 1..maximum) { "发布资产大小无效" }
            val url = raw.getString("browser_download_url")
            validateReleaseAssetUrl(url, tag, name)
            val digest = raw.optString("digest").takeIf(String::isNotBlank)?.let(::parseDigest)
            val parsed = ReleaseAsset(name, url, size, digest)
            if (name == APK_NAME) {
                require(apk == null) { "发布版包含重复安装包" }
                apk = parsed
            } else {
                require(checksums == null) { "发布版包含重复校验文件" }
                checksums = parsed
            }
        }
        return AppRelease(version, tag, pageUrl, requireNotNull(apk) { "发布版缺少安装包" }, requireNotNull(checksums) { "发布版缺少校验文件" })
    }

    fun expectedApkSha256(contents: String): String {
        val matches = contents.lineSequence().map(String::trim).mapNotNull { line ->
            val parts = line.split(Regex("\\s+"), limit = 2)
            if (parts.size != 2 || parts[1].removePrefix("*") != APK_NAME) null
            else parts[0].lowercase().takeIf(sha256Pattern::matches)
        }.toList()
        require(matches.size == 1) { "校验文件没有唯一的 $APK_NAME 记录" }
        return matches.single()
    }

    fun compareVersions(left: String, right: String): Int {
        val a = versionParts(left)
        val b = versionParts(right)
        for (index in a.indices) {
            val compared = a[index].compareTo(b[index])
            if (compared != 0) return compared
        }
        return 0
    }

    private fun canonicalVersion(value: String): String {
        val match = requireNotNull(versionPattern.matchEntire(value)) { "版本号格式无效" }
        return match.groupValues.drop(1).joinToString(".")
    }

    private fun versionParts(value: String): List<Long> {
        val canonical = canonicalVersion(value)
        return canonical.split('.').map { part ->
            part.toLongOrNull()?.takeIf { it <= Int.MAX_VALUE } ?: error("版本号超出范围")
        }
    }

    private fun parseDigest(value: String): String {
        require(value.startsWith("sha256:")) { "发布资产摘要算法无效" }
        return value.removePrefix("sha256:").lowercase().also {
            require(sha256Pattern.matches(it)) { "发布资产摘要无效" }
        }
    }

    private fun validateReleaseAssetUrl(value: String, tag: String, name: String) {
        val uri = URI(value)
        require(
            uri.scheme == "https" && uri.host == "github.com" && uri.userInfo == null && uri.fragment == null &&
                uri.rawPath == "/hxaxd/remote-everything/releases/download/$tag/$name",
        ) { "发布资产地址无效" }
    }
}
