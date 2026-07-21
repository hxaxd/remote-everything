package com.remoteeverything.app

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.net.toUri
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.remoteeverything.app.ui.AppRoot
import com.remoteeverything.app.ui.SessionViewModel
import com.remoteeverything.app.ui.theme.RemoteEverythingTheme
import com.remoteeverything.app.web.WebViewPool
import kotlinx.coroutines.launch

/**
 * 应用唯一 Activity:只负责窗口级职责(edge-to-edge、沉浸式、方向、内存回调),
 * 界面与状态全部交给 Compose 导航与 SessionViewModel。
 */
class MainActivity : ComponentActivity() {
    private val session: SessionViewModel by viewModels()
    private lateinit var pool: WebViewPool
    private var immersive = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        pool = WebViewPool(
            context = applicationContext,
            onExternal = { uri -> runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) } },
            onCertificateFailure = {
                Toast.makeText(this, "服务器证书验证失败,已阻止连接", Toast.LENGTH_LONG).show()
            },
            displayModeResolver = { appId ->
                session.settings.resolveDisplayMode(session.activeProfile.value?.installationId, appId)
            },
        )
        // 活动连接变化 → 重建 WebView 池会话
        lifecycleScope.launch {
            session.activeProfile.collect { config ->
                if (config == null) pool.destroyAll() else pool.configure(config, session.clientIdentityOf(config))
            }
        }
        setContent {
            RemoteEverythingTheme {
                AppRoot(
                    session = session,
                    pool = pool,
                    onImmersive = ::applyImmersive,
                    onOrientation = { requestedOrientation = it },
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

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (::pool.isInitialized) pool.trimMemory(level)
    }

    override fun onDestroy() {
        if (::pool.isInitialized) pool.destroyAll()
        super.onDestroy()
    }
}
