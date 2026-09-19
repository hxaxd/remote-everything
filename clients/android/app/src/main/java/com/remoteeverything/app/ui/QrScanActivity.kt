package com.remoteeverything.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.remoteeverything.app.R
import com.remoteeverything.app.i18n.messageKey
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.setup.SetupUri
import java.util.EnumSet
import kotlin.math.min

/**
 * Reading the invitation, on this app's own camera screen.
 *
 * Why this platform difference is not a choice (clients/README.md — the scanner is
 * one of the three sanctioned ones): iOS ships no system scanning API and HarmonyOS
 * hands its scanning to Scan Kit, while Android's only stock options are the
 * library's own capture activity — a landscape, red-lasered viewfinder that belongs
 * to another app's design, not this one's. So the preview is a [BarcodeView] this
 * screen owns, drawn over by an overlay this screen draws, standing up, in the
 * app's colours. The divergence ends at the shell: what leaves here is the same
 * invitation string the paste field accepts, parsed by the same [SetupUri].
 */
class QrScanActivity : ComponentActivity() {

    private lateinit var preview: BarcodeView
    private lateinit var overlay: ScanOverlayView
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
            decoderFactory = DefaultDecoderFactory(EnumSet.of(BarcodeFormat.QR_CODE))
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        root.addView(preview)
        overlay = ScanOverlayView(this)
        root.addView(
            overlay,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        val controls = topBar(density)
        val foot = bottomBar(density)
        root.addView(controls)
        root.addView(foot)
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
            glyph("✕", OnCamera) { finish() },
            FrameLayout.LayoutParams(dp(56, density), dp(56, density)).apply {
                gravity = Gravity.TOP or Gravity.START
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
            ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; topMargin = dp(18, density) },
        )
        addView(
            glyph("⚡", if (torchOn) Accent else OnCamera) { toggleTorch() },
            FrameLayout.LayoutParams(dp(56, density), dp(56, density)).apply {
                gravity = Gravity.TOP or Gravity.END
            },
        )
    }

    /** What the code is for, and what to do when the code was something else. */
    private fun bottomBar(density: Float): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
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

    private fun glyph(mark: String, color: Int, onClick: () -> Unit): TextView = TextView(this).apply {
        text = mark
        textSize = 20f
        gravity = Gravity.CENTER
        setTextColor(color)
        isClickable = true
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
        if (::preview.isInitialized) preview.pause()
        super.onPause()
    }

    override fun onDestroy() {
        if (::preview.isInitialized) preview.pause()
        super.onDestroy()
    }

    private fun toggleTorch() {
        torchOn = !torchOn
        runCatching { preview.setTorch(torchOn) }
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

/**
 * What sits over the camera: everything but the frame is dimmed, the frame's
 * corners are drawn, and nothing else is. The preview stays visible exactly where
 * a code has to be, which is the whole instruction.
 */
private class ScanOverlayView(context: Context) : View(context) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val frame = RectF()
    private val density = resources.displayMetrics.density

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        val side = min(width, height) * 0.68f
        val left = (width - side) / 2f
        val top = (height - side) / 2f
        frame.set(left, top, left + side, top + side)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (frame.isEmpty) return
        val radius = 28f * density
        path.reset()
        path.fillType = Path.FillType.EVEN_ODD
        path.addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
        path.addRoundRect(frame, radius, radius, Path.Direction.CW)
        paint.style = Paint.Style.FILL
        paint.color = Scrim
        canvas.drawPath(path, paint)

        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 4f * density
        paint.strokeCap = Paint.Cap.ROUND
        paint.color = Accent
        val arm = 34f * density
        // The brackets start past the rounded corner, so they read as the frame's
        // corners rather than as a box drawn over one.
        canvas.drawLine(frame.left + radius, frame.top, frame.left + radius + arm, frame.top, paint)
        canvas.drawLine(frame.left, frame.top + radius, frame.left, frame.top + radius + arm, paint)
        canvas.drawLine(frame.right - radius, frame.top, frame.right - radius - arm, frame.top, paint)
        canvas.drawLine(frame.right, frame.top + radius, frame.right, frame.top + radius + arm, paint)
        canvas.drawLine(frame.left + radius, frame.bottom, frame.left + radius + arm, frame.bottom, paint)
        canvas.drawLine(frame.left, frame.bottom - radius, frame.left, frame.bottom - radius - arm, paint)
        canvas.drawLine(frame.right - radius, frame.bottom, frame.right - radius - arm, frame.bottom, paint)
        canvas.drawLine(frame.right, frame.bottom - radius, frame.right, frame.bottom - radius - arm, paint)
    }
}

// The camera is dark on every theme, so these are the screen's own colours.
private val Accent = Color.parseColor("#8FB4DC")
private val OnCamera = Color.parseColor("#F2F2F2")
private val Danger = Color.parseColor("#E0A0A0")
private val Scrim = Color.parseColor("#99000000")
