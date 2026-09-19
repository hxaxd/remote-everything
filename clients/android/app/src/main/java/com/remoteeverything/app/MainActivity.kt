package com.remoteeverything.app

import com.remoteeverything.app.i18n.LocaleHelper
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.remoteeverything.app.ui.AppNav
import com.remoteeverything.app.theme.AppTheme
import com.remoteeverything.core.store.Language

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
            // The intent outlives its delivery: an activity that is recreated —
            // a language switch does exactly that — is handed the same intent
            // again, and without this the link would open the pair screen every
            // time. The data is consumed, so it leaves with its delivery.
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
                onStopOrDispose { vm.stopForegroundRefresh() }
            }
            val state by vm.state.collectAsStateWithLifecycle()
            AppTheme(state.settings.appearance) {
                ApplyLanguageOverride(state.settings.language)
                AppNav(vm)
            }
        }
    }

    /**
     * A language override lives in the context wrapped at attachBaseContext,
     * so changing it recreates the activity once. rememberSaveable survives
     * the recreation, which is what stops this from looping.
     */
    @Composable
    private fun ApplyLanguageOverride(language: Language) {
        val activity = LocalActivity.current
        var applied by rememberSaveable { mutableStateOf<Language?>(null) }
        LaunchedEffect(language) {
            val previous = applied
            applied = language
            if (previous != null && previous != language) {
                activity?.recreate()
            }
        }
    }
}
