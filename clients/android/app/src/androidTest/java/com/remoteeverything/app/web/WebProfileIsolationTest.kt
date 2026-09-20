package com.remoteeverything.app.web

import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class WebProfileIsolationTest {
    @Test
    fun sameIpAndParentDomainCookiesStayInTheirOwnProfile() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val a = "test-a-${UUID.randomUUID()}"
        val b = "test-b-${UUID.randomUUID()}"
        val views = mutableListOf<WebView>()
        val cookieWrites = CountDownLatch(2)
        try {
            instrumentation.runOnMainSync {
                assertTrue("This test requires a WebView with multi-profile support",
                    WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
                for (name in listOf(a, b)) {
                    val view = WebView(instrumentation.targetContext)
                    WebViewCompat.setProfile(view, name)
                    assertEquals(name, WebViewCompat.getProfile(view).name)
                    views += view
                }
                val cookies = ProfileStore.getInstance().getProfile(a)!!.cookieManager
                cookies.setCookie("https://127.0.0.1:8443/", "session=private-a; Path=/; Secure; HttpOnly") {
                    assertTrue(it)
                    cookieWrites.countDown()
                }
                cookies.setCookie("https://a.gateway.example/", "parent=private-a; Domain=gateway.example; Path=/; Secure") {
                    assertTrue(it)
                    cookieWrites.countDown()
                }
            }
            assertTrue("cookie writes timed out", cookieWrites.await(10, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                val store = ProfileStore.getInstance()
                val own = store.getProfile(a)!!.cookieManager
                val other = store.getProfile(b)!!.cookieManager
                // A different port really does share cookies inside one profile.
                assertTrue(own.getCookie("https://127.0.0.1:9443/").contains("session=private-a"))
                assertTrue(own.getCookie("https://b.gateway.example/").contains("parent=private-a"))
                assertNull(other.getCookie("https://127.0.0.1:9443/"))
                assertNull(other.getCookie("https://b.gateway.example/"))
                own.flush()
                views.forEach(WebView::destroy)
                views.clear()
                val reopened = WebView(instrumentation.targetContext)
                WebViewCompat.setProfile(reopened, a)
                views += reopened
                assertTrue(WebViewCompat.getProfile(reopened).cookieManager
                    .getCookie("https://127.0.0.1:8443/").contains("session=private-a"))
            }
        } finally {
            instrumentation.runOnMainSync {
                views.forEach(WebView::destroy)
                if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                    ProfileStore.getInstance().deleteProfile(a)
                    ProfileStore.getInstance().deleteProfile(b)
                }
            }
        }
    }
}
