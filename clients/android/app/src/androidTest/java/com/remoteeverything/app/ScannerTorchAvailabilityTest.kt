package com.remoteeverything.app

import android.Manifest
import android.content.Intent
import android.hardware.Camera
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.journeyapps.barcodescanner.BarcodeView
import com.remoteeverything.app.ui.QrScanActivity
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class ScannerTorchAvailabilityTest {
    @Test fun lightControlStaysVisibleAndReflectsTheActualCamera() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val activity = instrumentation.startActivitySync(
            QrScanActivity.intent(context).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as QrScanActivity
        fun descendants(view: View): List<View> = listOf(view) +
            if (view is ViewGroup) (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
        try {
            lateinit var preview: BarcodeView
            lateinit var light: ImageButton
            instrumentation.runOnMainSync {
                val views = descendants(activity.window.decorView)
                preview = views.filterIsInstance<BarcodeView>().single()
                light = views.filterIsInstance<ImageButton>().single { it.contentDescription == activity.getString(R.string.pair_scan_light) }
            }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
            var ready = false
            while (!ready && System.nanoTime() < deadline) {
                instrumentation.runOnMainSync { ready = preview.isPreviewActive }
                if (!ready) Thread.sleep(50)
            }
            assertTrue("Camera preview should start", ready)
            val read = CountDownLatch(1)
            var supported = false
            instrumentation.runOnMainSync {
                preview.changeCameraParameters { parameters ->
                    val modes = parameters.supportedFlashModes.orEmpty()
                    supported = Camera.Parameters.FLASH_MODE_TORCH in modes || Camera.Parameters.FLASH_MODE_ON in modes
                    read.countDown()
                    parameters
                }
            }
            assertTrue("Read real camera capabilities", read.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                assertEquals(View.VISIBLE, light.visibility)
                assertEquals(supported, light.isEnabled)
                assertFalse(light.isSelected)
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
