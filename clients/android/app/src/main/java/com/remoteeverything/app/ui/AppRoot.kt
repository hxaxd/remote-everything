package com.remoteeverything.app.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.remoteeverything.app.ui.components.CenteredLoading
import com.remoteeverything.app.ui.screens.CatalogScreen
import com.remoteeverything.app.ui.screens.ConnectionsScreen
import com.remoteeverything.app.ui.screens.RemoteScreen
import com.remoteeverything.app.ui.screens.SettingsScreen
import com.remoteeverything.app.ui.screens.SetupWizardScreen
import com.remoteeverything.app.web.WebViewPool

object Routes {
    const val CONNECTIONS = "connections"
    const val SETUP = "setup"
    const val CATALOG = "catalog"
    const val SETTINGS = "settings"
    const val REMOTE = "remote/{appId}"
    fun remote(appId: String) = "remote/$appId"
}

/**
 * 导航骨架。返回栈由 Navigation 托管,天然修复旧版"管理连接无法返回"等问题。
 */
@Composable
fun AppRoot(
    session: SessionViewModel,
    pool: WebViewPool,
    onImmersive: (Boolean) -> Unit,
    onOrientation: (Int) -> Unit,
) {
    val start by session.startState.collectAsStateWithLifecycle()
    val activeProfile by session.activeProfile.collectAsStateWithLifecycle()
    val nav = rememberNavController()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        session.bootstrap()
    }
    LaunchedEffect(Unit) {
        session.messages.collect { snackbar.showSnackbar(it) }
    }

    // 活动连接被删除/吊销时,强制回到连接管理
    LaunchedEffect(activeProfile) {
        if (activeProfile == null && start !is StartState.Loading) {
            val route = nav.currentDestination?.route
            if (route == Routes.CATALOG || route == Routes.SETTINGS || route == Routes.REMOTE) {
                nav.navigate(Routes.CONNECTIONS) { popUpTo(0) }
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        when (val current = start) {
            is StartState.Loading -> Splash()
            else -> AppNavHost(
                nav = nav,
                session = session,
                pool = pool,
                start = current,
                onImmersive = onImmersive,
                onOrientation = onOrientation,
            )
        }
        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }
}

@Composable
private fun Splash() {
    Surface(color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CenteredLoading()
        }
    }
}

@Composable
private fun AppNavHost(
    nav: NavHostController,
    session: SessionViewModel,
    pool: WebViewPool,
    start: StartState,
    onImmersive: (Boolean) -> Unit,
    onOrientation: (Int) -> Unit,
) {
    // startDestination 只在首次组合时生效;向导完成后 start 会变为 Ready,必须钉住初始值
    val startDestination = remember {
        when (start) {
            is StartState.NoProfile -> Routes.CONNECTIONS
            is StartState.PendingActivation -> Routes.SETUP
            is StartState.Ready -> Routes.CATALOG
            is StartState.Loading -> Routes.CONNECTIONS
        }
    }

    // 非远程屏:退出沉浸,方向跟随全局设置
    LaunchedEffect(nav) {
        nav.currentBackStackEntryFlow.collect { entry ->
            val route = entry.destination.route
            if (route != Routes.REMOTE) {
                onImmersive(false)
                onOrientation(session.settings.resolveOrientation(null, null))
            }
        }
    }

    NavHost(
        navController = nav,
        startDestination = startDestination,
        enterTransition = {
            androidx.compose.animation.slideInHorizontally(initialOffsetX = { it / 4 }) + androidx.compose.animation.fadeIn()
        },
        exitTransition = {
            androidx.compose.animation.slideOutHorizontally(targetOffsetX = { -it / 4 }) + androidx.compose.animation.fadeOut()
        },
        popEnterTransition = {
            androidx.compose.animation.slideInHorizontally(initialOffsetX = { -it / 4 }) + androidx.compose.animation.fadeIn()
        },
        popExitTransition = {
            androidx.compose.animation.slideOutHorizontally(targetOffsetX = { it / 4 }) + androidx.compose.animation.fadeOut()
        },
    ) {
        composable(Routes.CONNECTIONS) {
            ConnectionsScreen(
                session = session,
                canPopBack = nav.previousBackStackEntry != null,
                onBack = { nav.popBackStack() },
                onOpenCatalog = {
                    nav.navigate(Routes.CATALOG) { popUpTo(0) }
                },
                onBeginWizard = { nav.navigate(Routes.SETUP) },
            )
        }
        composable(Routes.SETUP) {
            SetupWizardScreen(
                session = session,
                onCompleted = {
                    nav.navigate(Routes.CATALOG) { popUpTo(0) }
                },
                onCancel = { nav.popBackStack() },
            )
        }
        composable(Routes.CATALOG) {
            CatalogScreen(
                session = session,
                pool = pool,
                onSettings = { nav.navigate(Routes.SETTINGS) },
                onEnterApp = { appId -> nav.navigate(Routes.remote(appId)) },
            )
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(
                session = session,
                onBack = { nav.popBackStack() },
                onManageConnections = { nav.navigate(Routes.CONNECTIONS) },
            )
        }
        composable(Routes.REMOTE) { entry ->
            val appId = entry.arguments?.getString("appId").orEmpty()
            RemoteScreen(
                appId = appId,
                session = session,
                pool = pool,
                onImmersive = onImmersive,
                onOrientation = onOrientation,
                onExitToCatalog = { nav.popBackStack() },
            )
        }
    }
}
