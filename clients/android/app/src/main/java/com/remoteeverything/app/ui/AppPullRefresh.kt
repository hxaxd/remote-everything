package com.remoteeverything.app.ui

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Native pull gestures; the list makes room for an unboxed progress ring. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppPullRefresh(
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val state = rememberPullToRefreshState()
    val threshold = PullToRefreshDefaults.PositionalThreshold
    val thresholdPx = with(LocalDensity.current) { threshold.toPx() }
    PullToRefreshBox(
        isRefreshing = isRefreshing, onRefresh = onRefresh, state = state,
        modifier = modifier.clipToBounds(),
        indicator = {
            Box(
                modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth()
                    .height(threshold * state.distanceFraction)
                    .graphicsLayer { alpha = state.distanceFraction.coerceIn(0f, 1f) },
                contentAlignment = Alignment.Center,
            ) {
                if (isRefreshing) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp), strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary, trackColor = Color.Transparent,
                    )
                } else {
                    CircularProgressIndicator(
                        progress = { state.distanceFraction.coerceIn(0f, 1f) },
                        modifier = Modifier.size(24.dp), strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary, trackColor = Color.Transparent,
                    )
                }
            }
        },
    ) {
        Box(
            modifier = Modifier.fillMaxSize().offset {
                IntOffset(0, (thresholdPx * state.distanceFraction).roundToInt())
            },
            content = content,
        )
    }
}
