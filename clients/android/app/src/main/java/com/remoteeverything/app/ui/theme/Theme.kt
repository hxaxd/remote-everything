package com.remoteeverything.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val AppColorScheme = darkColorScheme(
    primary = Blue400,
    onPrimary = Color(0xFF0B2559),
    primaryContainer = Blue900,
    onPrimaryContainer = Blue100,
    secondary = Slate400,
    onSecondary = Slate950,
    secondaryContainer = Slate800,
    onSecondaryContainer = Color(0xFFCBD5E1),
    tertiary = Green400,
    onTertiary = Color(0xFF052E16),
    tertiaryContainer = Green900,
    onTertiaryContainer = Green100,
    error = Red400,
    onError = Color(0xFF450A0A),
    errorContainer = Red900,
    onErrorContainer = Red100,
    background = Slate950,
    onBackground = Slate100,
    surface = Slate950,
    onSurface = Slate100,
    surfaceVariant = Slate900,
    onSurfaceVariant = Slate400,
    surfaceContainerLowest = Color(0xFF01040F),
    surfaceContainerLow = Slate900,
    surfaceContainer = Slate850,
    surfaceContainerHigh = Slate800,
    surfaceContainerHighest = Color(0xFF28364E),
    outline = Slate700,
    outlineVariant = Color(0xFF22314A),
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

val LocalSemanticColors = staticCompositionLocalOf {
    SemanticColors(
        ok = Green400,
        okContainer = Green900,
        onOkContainer = Green100,
        warn = Amber400,
        warnContainer = Amber900,
        onWarnContainer = Amber100,
    )
}

val MaterialTheme.semantic: SemanticColors
    @Composable get() = LocalSemanticColors.current

@Composable
fun RemoteEverythingTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = AppColorScheme,
        typography = AppTypography,
        shapes = AppShapes,
        content = content,
    )
}
