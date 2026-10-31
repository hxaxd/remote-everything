package com.remoteeverything.app

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.remoteeverything.app.i18n.LocaleHelper
import com.remoteeverything.core.store.Language
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class LocalizedConfigurationTest {
    @Test fun localeOverridesFollowRotationWithoutAnActivityRestart() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val contexts = Language.entries.map { LocaleHelper.wrap(activity, it) }
        val previous = activity.requestedOrientation
        try {
            for ((requested, expected) in listOf(
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT to Configuration.ORIENTATION_PORTRAIT,
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE to Configuration.ORIENTATION_LANDSCAPE,
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT to Configuration.ORIENTATION_PORTRAIT,
            )) {
                instrumentation.runOnMainSync { activity.requestedOrientation = requested }
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
                var matches = false
                while (!matches && System.nanoTime() < deadline) {
                    instrumentation.runOnMainSync {
                        matches = activity.resources.configuration.orientation == expected
                    }
                    if (!matches) Thread.sleep(50)
                }
                assertTrue("Activity must follow requested orientation", matches)
                instrumentation.waitForIdleSync()
                instrumentation.runOnMainSync {
                    assertTrue(!activity.isDestroyed)
                    for (context in contexts) {
                        assertEquals(expected, context.resources.configuration.orientation)
                        assertEquals(activity.resources.configuration.screenWidthDp, context.resources.configuration.screenWidthDp)
                        assertEquals(activity.resources.configuration.screenHeightDp, context.resources.configuration.screenHeightDp)
                    }
                }
            }
        } finally {
            instrumentation.runOnMainSync {
                activity.requestedOrientation = previous
                activity.finish()
            }
        }
    }
}
