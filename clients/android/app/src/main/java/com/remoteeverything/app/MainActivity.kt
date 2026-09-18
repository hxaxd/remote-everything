package com.remoteeverything.app

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
import com.remoteeverything.app.ui.theme.AppTheme
import com.remoteeverything.core.store.Language

class MainActivity : ComponentActivity() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocaleHelper.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val vm: AppViewModel = viewModel()
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
