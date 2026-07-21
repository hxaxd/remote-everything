package com.remoteeverything.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UpdateProtocolTest {
    @Test
    fun latestReleaseRequiresExactProjectAssets() {
        val release = UpdateProtocol.parseLatestRelease(releaseJson())
        assertEquals("3.4.0", release.versionName)
        assertEquals("a".repeat(64), release.apk.digest)
        assertThrows(IllegalArgumentException::class.java) {
            UpdateProtocol.parseLatestRelease(releaseJson().replace("github.com/hxaxd", "github.com/attacker"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdateProtocol.parseLatestRelease(releaseJson().replace("app-release.apk", "other.apk"))
        }
    }

    @Test
    fun checksumRequiresOneExactApkEntry() {
        val expected = "b".repeat(64)
        assertEquals(expected, UpdateProtocol.expectedApkSha256("$expected  app-release.apk\n"))
        assertThrows(IllegalArgumentException::class.java) {
            UpdateProtocol.expectedApkSha256("$expected  app-release.apk\n$expected  app-release.apk\n")
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdateProtocol.expectedApkSha256("$expected  app-debug.apk\n")
        }
    }

    @Test
    fun semanticVersionsAreComparedNumerically() {
        assertEquals(1, UpdateProtocol.compareVersions("3.10.0", "3.9.9"))
        assertEquals(0, UpdateProtocol.compareVersions("v3.4.0", "3.4.0"))
        assertEquals(-1, UpdateProtocol.compareVersions("2.9.9", "3.0.0"))
    }

    private fun releaseJson(): String = """
        {
          "tag_name":"v3.4.0",
          "html_url":"https://github.com/hxaxd/remote-everything/releases/tag/v3.4.0",
          "draft":false,
          "prerelease":false,
          "assets":[
            {"name":"app-release.apk","state":"uploaded","size":1234,"digest":"sha256:${"a".repeat(64)}","browser_download_url":"https://github.com/hxaxd/remote-everything/releases/download/v3.4.0/app-release.apk"},
            {"name":"SHA256SUMS","state":"uploaded","size":321,"digest":"sha256:${"c".repeat(64)}","browser_download_url":"https://github.com/hxaxd/remote-everything/releases/download/v3.4.0/SHA256SUMS"}
          ]
        }
    """.trimIndent()
}
