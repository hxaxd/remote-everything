package com.remoteeverything.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.remoteeverything.app.i18n.l10n
import com.remoteeverything.app.theme.LocalSemanticColors
import com.remoteeverything.core.model.LinkKind
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.Path

/** The pieces more than one screen draws: a state chip and the centered empty-or-broken message. */

@Composable
fun StatusChip(label: String, color: Color) {
    Surface(
        shape = RoundedCornerShape(50),
        color = color.copy(alpha = 0.12f),
    ) {
        Box(modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp)) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = color)
        }
    }
}

/**
 * The ways in this phone has to one machine: a local link, a link over the tunnel,
 * or both — each a dot and a word, with the one that would actually be taken
 * standing out and the other left quiet. Two links is the ordinary state of a phone
 * that paired over the internet and later met the gateway at home, and seeing both
 * is how a person knows that losing one of them is not losing the machine.
 */
@Composable
fun LinkChips(paths: List<Path>, inUse: Path?) {
    val semantic = LocalSemanticColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for (kind in listOf(LinkKind.LOCAL, LinkKind.TUNNEL)) {
            if (paths.none { it.link == kind }) continue
            val live = inUse != null && inUse.link == kind
            val color = when {
                !live -> semantic.textTertiary
                kind == LinkKind.LOCAL -> semantic.ok
                else -> semantic.warn
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Box(modifier = Modifier.size(7.dp).background(color, RoundedCornerShape(50)))
                Text(
                    l10n(if (kind == LinkKind.LOCAL) MessageKeys.NODE_LAN else MessageKeys.NODE_TUNNEL),
                    style = MaterialTheme.typography.labelMedium,
                    color = color,
                )
            }
        }
    }
}

@Composable
fun CenteredMessage(
    title: String,
    modifier: Modifier = Modifier,
    body: String? = null,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (body != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                body,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        if (action != null && onAction != null) {
            Spacer(Modifier.height(24.dp))
            Button(onClick = onAction) { Text(action) }
        }
    }
}
