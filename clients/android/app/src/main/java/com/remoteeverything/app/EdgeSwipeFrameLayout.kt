package com.remoteeverything.app

import android.content.Context
import android.view.MotionEvent
import android.widget.FrameLayout

class EdgeSwipeFrameLayout(context: Context) : FrameLayout(context) {
    var onEdgeSwipe: (() -> Unit)? = null
    private var tracking = false
    private var intercepting = false
    private var direction = 1f
    private var downX = 0f
    private var downY = 0f
    private val edgeWidth = 30f * resources.displayMetrics.density
    private val interceptDistance = 14f * resources.displayMetrics.density
    private val triggerDistance = 72f * resources.displayMetrics.density

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                direction = if (event.x <= edgeWidth) 1f else -1f
                tracking = event.x <= edgeWidth || event.x >= width - edgeWidth
                intercepting = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (tracking) {
                    val horizontal = (event.x - downX) * direction
                    val vertical = kotlin.math.abs(event.y - downY)
                    if (horizontal > interceptDistance && horizontal > vertical * 1.2f) {
                        intercepting = true
                        return true
                    }
                    if (vertical > interceptDistance || horizontal < -interceptDistance) tracking = false
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                tracking = false
                intercepting = false
            }
        }
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!intercepting) return super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            if ((event.x - downX) * direction >= triggerDistance) performClick()
            tracking = false
            intercepting = false
        } else if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
            tracking = false
            intercepting = false
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        onEdgeSwipe?.invoke()
        return true
    }
}
