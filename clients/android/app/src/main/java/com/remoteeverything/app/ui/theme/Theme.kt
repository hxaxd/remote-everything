package com.remoteeverything.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val LightColorScheme = lightColorScheme(
    primary = Amber700,
    onPrimary = Color.White,
    primaryContainer = Amber100,
    onPrimaryContainer = Amber950,
    secondary = Stone500,
    onSecondary = Color.White,
    secondaryContainer = Stone200,
    onSecondaryContainer = Stone800,
    tertiary = Green600,
    onTertiary = Color.White,
    tertiaryContainer = Green100,
    onTertiaryContainer = Green900,
    error = Red600,
    onError = Color.White,
    errorContainer = Red100,
    onErrorContainer = Red900,
    background = Stone50,
    onBackground = Stone900,
    surface = Stone50,
    onSurface = Stone900,
    surfaceVariant = Stone100,
    onSurfaceVariant = Stone500,
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Stone100,
    surfaceContainer = Color(0xFFEFEDEB),
    surfaceContainerHigh = Stone200,
    surfaceContainerHighest = Color(0xFFDDD9D5),
    outline = Stone300,
    outlineVariant = Stone200,
    scrim = Color(0x52000000),
)

private val DarkColorScheme = darkColorScheme(
    primary = Amber400,
    onPrimary = Amber950,
    primaryContainer = Amber900,
    onPrimaryContainer = Amber100,
    secondary = Stone400,
    onSecondary = Stone900,
    secondaryContainer = Stone700,
    onSecondaryContainer = Stone200,
    tertiary = Green400,
    onTertiary = Green950,
    tertiaryContainer = Green900,
    onTertiaryContainer = Green100,
    error = Red400,
    onError = Red950,
    errorContainer = Red900,
    onErrorContainer = Color(0xFFFECACA),
    background = Stone950,
    onBackground = Stone100,
    surface = Stone950,
    onSurface = Stone100,
    surfaceVariant = Stone900,
    onSurfaceVariant = Stone400,
    surfaceContainerLowest = Color(0xFF060505),
    surfaceContainerLow = Color(0xFF141210),
    surfaceContainer = Stone900,
    surfaceContainerHigh = Stone800,
    surfaceContainerHighest = Color(0xFF353230),
    outline = Stone700,
    outlineVariant = Stone800,
    scrim = Color(0xB3000000),
)

private val AppTypography = Typography(
    headlineLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 30.sp, lineHeight = 38.sp),
    headlineMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 26.sp, lineHeight = 34.sp),
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 20.sp, lineHeight = 28.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 24.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 19.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp),
)

private val AppShapes = Shapes(
    small = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
    large = androidx.compose.foundation.shape.RoundedCornerShape(22.dp),
    extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(30.dp),
)

/** 语义色:运行/告警等状态,M3 槽位之外的扩展。 */
@Immutable
data class SemanticColors(
    val ok: Color,
    val okContainer: Color,
    val onOkContainer: Color,
    val warn: Color,
    val warnContainer: Color,
    val onWarnContainer: Color,
)

private val LightSemantic = SemanticColors(
    ok = Green600,
    okContainer = Green100,
    onOkContainer = Green900,
    warn = Amber700,
    warnContainer = Amber100,
    onWarnContainer = Amber950,
)

private val DarkSemantic = SemanticColors(
    ok = Green400,
    okContainer = Green900,
    onOkContainer = Green100,
    warn = Amber400,
    warnContainer = Amber900,
    onWarnContainer = Amber100,
)

val LocalSemanticColors = staticCompositionLocalOf { LightSemantic }

val MaterialTheme.semantic: SemanticColors
    @Composable get() = LocalSemanticColors.current

const val THEME_SYSTEM = "system"
const val THEME_LIGHT = "light"
const val THEME_DARK = "dark"

@Composable
fun RemoteEverythingTheme(themeMode: String = THEME_SYSTEM, content: @Composable () -> Unit) {
    val dark = when (themeMode) {
        THEME_LIGHT -> false
        THEME_DARK -> true
        else -> isSystemInDarkTheme()
    }
    CompositionLocalProvider(LocalSemanticColors provides if (dark) DarkSemantic else LightSemantic) {
        MaterialTheme(
            colorScheme = if (dark) DarkColorScheme else LightColorScheme,
            typography = AppTypography,
            shapes = AppShapes,
            content = content,
        )
    }
}
