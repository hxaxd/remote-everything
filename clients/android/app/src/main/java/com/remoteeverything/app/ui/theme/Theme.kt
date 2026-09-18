package com.remoteeverything.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.remoteeverything.core.store.Appearance

// The palette all three clients share, and it is nearly colourless: the accent
// and the semantic colours are the only colour the interface itself has.

private val LightScheme = lightColorScheme(
    primary = Color(0xFF3B6EA5),
    onPrimary = Color(0xFFFFFFFF),
    background = Color(0xFFFAFAFA),
    onBackground = Color(0xFF1A1A1A),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1A1A1A),
    onSurfaceVariant = Color(0xFF6B6B6B),
    outline = Color(0xFFE5E5E5),
    error = Color(0xFFB05454),
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFF6E97C4),
    onPrimary = Color(0xFF0F1B28),
    background = Color(0xFF141414),
    onBackground = Color(0xFFE8E8E8),
    surface = Color(0xFF1E1E1E),
    onSurface = Color(0xFFE8E8E8),
    onSurfaceVariant = Color(0xFFA0A0A0),
    outline = Color(0xFF2E2E2E),
    error = Color(0xFFC47A7A),
)

/** Semantic colours Material has no slot for (style.md §2). */
data class SemanticColors(
    val ok: Color,
    val warn: Color,
    val offline: Color,
    val textTertiary: Color,
)

private val LightSemantic = SemanticColors(
    ok = Color(0xFF3D8B6D),
    warn = Color(0xFFB08A3E),
    offline = Color(0xFF9C9C9C),
    textTertiary = Color(0xFF9C9C9C),
)

private val DarkSemantic = SemanticColors(
    ok = Color(0xFF63A98B),
    warn = Color(0xFFC9A55C),
    offline = Color(0xFF6E6E6E),
    textTertiary = Color(0xFF6E6E6E),
)

val LocalSemanticColors = staticCompositionLocalOf { LightSemantic }

private val AppTypography = Typography(
    titleLarge = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, lineHeight = 28.sp),
    titleMedium = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.Medium, lineHeight = 24.sp),
    bodyLarge = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal, lineHeight = 21.sp),
    labelMedium = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal, lineHeight = 18.sp),
    labelSmall = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Normal, lineHeight = 17.sp),
)

private val AppShapes = Shapes(
    small = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
)

@Composable
fun AppTheme(appearance: Appearance, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        Appearance.SYSTEM -> isSystemInDarkTheme()
        Appearance.LIGHT -> false
        Appearance.DARK -> true
    }
    CompositionLocalProvider(
        LocalSemanticColors provides if (dark) DarkSemantic else LightSemantic,
    ) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme else LightScheme,
            typography = AppTypography,
            shapes = AppShapes,
            content = content,
        )
    }
}
