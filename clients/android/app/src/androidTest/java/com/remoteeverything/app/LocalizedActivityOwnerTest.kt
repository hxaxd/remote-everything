package com.remoteeverything.app

import android.content.Intent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalContext
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.remoteeverything.app.i18n.LocaleHelper
import com.remoteeverything.core.store.Language
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class LocalizedActivityOwnerTest {
    @Test fun localizedScreensCanLaunchScannerAndPermissionResults() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            for (language in Language.entries) {
                val rendered = CountDownLatch(1)
                val failure = AtomicReference<Throwable?>()
                instrumentation.runOnMainSync {
                    val context = LocaleHelper.wrap(activity, language)
                    activity.setContent {
                        CompositionLocalProvider(LocalContext provides context) {
                            val owner = LocalActivityResultRegistryOwner.current
                            SideEffect {
                                try { assertSame("Scanner result owner for $language", activity, owner) }
                                catch (error: Throwable) { failure.set(error) }
                                rendered.countDown()
                            }
                        }
                    }
                }
                assertTrue(rendered.await(10, TimeUnit.SECONDS))
                failure.get()?.let { throw AssertionError(it) }
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
