package com.remoteeverything.app

import com.remoteeverything.app.i18n.LocaleHelper
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.core.view.WindowCompat
import com.remoteeverything.app.ui.AppNav
import com.remoteeverything.app.theme.AppTheme
import com.remoteeverything.core.store.Language
import com.remoteeverything.core.store.Appearance

class MainActivity : ComponentActivity() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocaleHelper.wrap(newBase))
    }

    private var vmRef: AppModel? = null

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleInvitationIntent(intent)
    }

    private fun handleInvitationIntent(intent: android.content.Intent?) {
        val uri = intent?.dataString
        if (uri != null && uri.startsWith("remote-everything://setup")) {
            vmRef?.stageInvitation(uri)
            // Consume the invitation once so lifecycle recreation cannot stage it again.
            intent?.data = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val vm: AppModel = viewModel()
            vmRef = vm
            LaunchedEffect(Unit) {
                handleInvitationIntent(intent)
            }
            LifecycleStartEffect(Unit) {
                vm.startForegroundRefresh()
                // A device still waiting for its operator is asked about again the
                // moment the app is back, the way the other clients answer a
                // relaunch — a 10-minute window that ran out overnight is not a
                // pairing that stopped being waiting.
                if (vm.state.value.pairing is PairingUiState.Pending) {
                    vm.resumePendingPairing()
                }
                onStopOrDispose { vm.stopForegroundRefresh() }
            }
            val state by vm.state.collectAsStateWithLifecycle()
            val dark = when (state.settings.appearance) {
                Appearance.SYSTEM -> isSystemInDarkTheme()
                Appearance.LIGHT -> false
                Appearance.DARK -> true
            }
            SideEffect {
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
            AppTheme(state.settings.appearance) {
                LocalizedContent(state.settings.language) { AppNav(vm) }
            }
        }
    }

    @Composable
    private fun LocalizedContent(language: Language, content: @Composable () -> Unit) {
        val base = LocalContext.current
        val configuration = LocalConfiguration.current
        val localized = remember(base, configuration, language) { LocaleHelper.wrap(base, language) }
        CompositionLocalProvider(
            LocalContext provides localized,
            LocalConfiguration provides localized.resources.configuration,
            LocalResources provides localized.resources,
        ) {
            content()
        }
    }
}
