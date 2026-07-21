package com.remoteeverything.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.remoteeverything.app.ui.AppRoot
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.theme.RemoteEverythingTheme
import kotlinx.coroutines.launch

/**
 * 主 Activity 负责目录、连接与设置；远程网页由原生 RemoteActivity 独立承载。
 */
class MainActivity : ComponentActivity() {
    private val session: SessionViewModel by viewModels()
    private var immersive = false
    private var isDarkTheme = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 主题模式变化时同步系统栏明暗,确保手动浅色/深色下图标也正确
        lifecycleScope.launch {
            session.themeMode.collect { mode ->
                isDarkTheme = when (mode) {
                    "light" -> false
                    "dark" -> true
                    else -> resources.configuration.isNightModeActive
                }
            }
        }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ) { isDarkTheme },
            navigationBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ) { isDarkTheme },
        )
        setContent {
            val themeMode by session.themeMode.collectAsStateWithLifecycle()
            RemoteEverythingTheme(themeMode = themeMode) {
                AppRoot(
                    session = session,
                    onImmersive = ::applyImmersive,
                    onOrientation = { requestedOrientation = it },
                    onOpenRemote = { app -> startActivity(RemoteActivity.intent(this, app)) },
                )
            }
        }
    }

    private fun applyImmersive(enabled: Boolean) {
        immersive = enabled
        runCatching {
            val controller = WindowInsetsControllerCompat(window, window.decorView)
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (enabled) controller.hide(WindowInsetsCompat.Type.systemBars()) else controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && immersive) applyImmersive(true)
    }

}
