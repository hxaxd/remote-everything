package com.remoteeverything.app.ui

import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.remoteeverything.app.AppViewModel

@Composable
fun AppNav(vm: AppViewModel) {
    val nav = rememberNavController()
    NavHost(navController = nav, startDestination = "home") {
        composable("home") {
            HomeScreen(
                vm = vm,
                onAdd = { nav.navigate("pair") },
                onSettings = { nav.navigate("settings") },
                onNode = { node -> nav.navigate("node/${node.id}") },
            )
        }
        composable("pair") {
            PairScreen(vm = vm, onBack = { nav.popBackStack() })
        }
        composable("settings") {
            SettingsScreen(vm = vm, onBack = { nav.popBackStack() })
        }
        composable(
            route = "node/{nodeId}",
            arguments = listOf(navArgument("nodeId") { type = NavType.StringType }),
        ) { entry ->
            NodeScreen(
                vm = vm,
                nodeId = entry.arguments?.getString("nodeId").orEmpty(),
                onBack = { nav.popBackStack() },
            )
        }
    }
}
