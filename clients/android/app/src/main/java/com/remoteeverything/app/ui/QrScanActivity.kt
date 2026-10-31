package com.remoteeverything.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.hardware.Camera
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ImageButton
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.CameraPreview
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.remoteeverything.app.R
import com.remoteeverything.app.i18n.LocaleHelper
import com.remoteeverything.app.i18n.messageKey
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.setup.SetupUri
import java.util.EnumSet

/**
 * Full-window invitation scanner with close and light controls.
 * The same [SetupUri] parser validates camera results and pasted links.
 */
@Suppress("DEPRECATION") // ZXing owns this Camera instance and serializes its parameter changes.
class QrScanActivity : ComponentActivity() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocaleHelper.wrap(newBase))
    }

    private lateinit var preview: BarcodeView
    private lateinit var light: ImageButton
    private lateinit var hint: TextView
    private var torchOn = false
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            // Reached without the permission the caller should have asked for: there
            // is no preview to show and no code to read. The screen still goes
            // through its whole lifecycle, so nothing below may assume a camera.
            finish()
            return
        }
        buildUi()
    }

    private fun buildUi() {
        val density = resources.displayMetrics.density
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        preview = BarcodeView(this).apply {
            setMarginFraction(0.0)
            decoderFactory = DefaultDecoderFactory(EnumSet.of(BarcodeFormat.QR_CODE))
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        root.addView(preview)
        val controls = topBar(density)
        val foot = bottomBar(density)
        root.addView(controls)
        root.addView(foot)
        preview.addStateListener(object : CameraPreview.StateListener {
            override fun previewSized() = Unit
            override fun previewStarted() { readTorchState() }
            override fun previewStopped() { light.isEnabled = false }
            override fun cameraClosed() = Unit
            override fun cameraError(error: Exception) { light.isEnabled = false }
        })
        // The camera runs under the whole window — this build is edge-to-edge by
        // default (the app targets a version where the system bars are overlays) —
        // but the controls do not: a button under the status bar is a button the
        // notification shade takes the touch for. The bars keep their insets, the
        // picture keeps the whole screen.
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            controls.setPadding(0, bars.top, 0, 0)
            foot.setPadding(0, 0, 0, bars.bottom)
            insets
        }
        setContentView(root)
        ViewCompat.requestApplyInsets(root)
    }

    /** The way out, and the one light this screen has to offer. */
    private fun topBar(density: Float): View = FrameLayout(this).apply {
        addView(
            control(android.R.drawable.ic_menu_close_clear_cancel, getString(messageKey(MessageKeys.ACTION_BACK))) { finish() },
            FrameLayout.LayoutParams(dp(48, density), dp(48, density)).apply {
                gravity = Gravity.TOP or Gravity.START
                leftMargin = dp(16, density); topMargin = dp(16, density)
            },
        )
        addView(
            TextView(this@QrScanActivity).apply {
                text = getString(messageKey(MessageKeys.PAIR_SCAN))
                setTextColor(OnCamera)
                textSize = 16f
            },
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; topMargin = dp(96, density) },
        )
    }

    /** What the code is for, and what to do when the code was something else. */
    private fun bottomBar(density: Float): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        light = control(R.drawable.ic_scan_light, getString(messageKey(MessageKeys.PAIR_SCAN_LIGHT))) { toggleTorch() }
        light.isEnabled = false
        light.alpha = 0.4f
        addView(light, LinearLayout.LayoutParams(dp(56, density), dp(56, density)).apply { bottomMargin = dp(16, density) })
        hint = TextView(this@QrScanActivity).apply {
            text = getString(messageKey(MessageKeys.PAIR_SCAN_BODY))
            setTextColor(OnCamera)
            textSize = 14f
            gravity = Gravity.CENTER
            maxLines = 2
        }
        addView(hint)
        layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM,
        ).apply {
            bottomMargin = dp(72, density)
            leftMargin = dp(24, density)
            rightMargin = dp(24, density)
        }
    }

    private fun control(icon: Int, label: String, onClick: () -> Unit): ImageButton = ImageButton(this).apply {
        setImageResource(icon)
        setColorFilter(OnCamera)
        contentDescription = label
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.parseColor("#55222222")) }
        val inset = dp(12, resources.displayMetrics.density)
        setPadding(inset, inset, inset, inset)
        setOnClickListener { onClick() }
    }

    // --- the camera ------------------------------------------------------------

    override fun onResume() {
        super.onResume()
        if (!::preview.isInitialized) return
        preview.resume()
        preview.decodeContinuous(callback)
    }

    override fun onPause() {
        if (::preview.isInitialized) {
            preview.setTorch(false)
            preview.pause()
        }
        super.onPause()
    }

    override fun onDestroy() {
        if (::preview.isInitialized) preview.pause()
        super.onDestroy()
    }

    private fun toggleTorch() {
        if (!preview.isPreviewActive || !light.isEnabled) return
        light.isEnabled = false
        preview.setTorch(!torchOn)
        readTorchState()
    }

    private fun readTorchState() {
        // Runs after the queued torch change on ZXing's camera thread. Reflect
        // the camera's actual mode rather than assuming a tap was accepted.
        preview.changeCameraParameters { parameters ->
            val modes = parameters.supportedFlashModes.orEmpty()
            val supported = Camera.Parameters.FLASH_MODE_TORCH in modes || Camera.Parameters.FLASH_MODE_ON in modes
            val on = parameters.flashMode == Camera.Parameters.FLASH_MODE_TORCH ||
                parameters.flashMode == Camera.Parameters.FLASH_MODE_ON
            light.post {
                if (preview.isPreviewActive) {
                    torchOn = on
                    light.alpha = if (supported) 1f else 0.4f
                    light.setColorFilter(if (on) Accent else OnCamera)
                    light.isSelected = on
                    light.isEnabled = supported
                }
            }
            parameters
        }
    }

    private val callback = object : BarcodeCallback {
        override fun barcodeResult(result: BarcodeResult?) {
            if (handled) return
            val text = result?.text?.trim().orEmpty()
            if (text.isEmpty()) return
            // A code that is not an invitation is not an answer: the scan keeps
            // looking, and the screen says why this one was passed over. (The
            // decoder's own thread is not this screen's, so the words go through
            // the main thread like every other view write.)
            val invitation = runCatching { SetupUri.parse(text) }.getOrNull()
            if (invitation == null) {
                runOnUiThread {
                    hint.text = getString(messageKey(MessageKeys.PAIR_SCAN_FAILED))
                    hint.setTextColor(Danger)
                }
                return
            }
            handled = true
            preview.pause()
            setResult(RESULT_OK, Intent().putExtra(ExtraCode, text))
            finish()
        }
    }

    private fun dp(value: Int, density: Float): Int = (value * density).toInt()

    companion object {
        const val ExtraCode = "code"

        /**
         * A scan, asked for as a result: the caller already made sure the camera
         * may be opened, and gets back the string the field takes.
         */
        fun intent(context: Context): Intent = Intent(context, QrScanActivity::class.java)
    }
}

// The camera is dark on every theme, so these are the screen's own colours.
private val Accent = Color.parseColor("#8FB4DC")
private val OnCamera = Color.parseColor("#F2F2F2")
private val Danger = Color.parseColor("#E0A0A0")
