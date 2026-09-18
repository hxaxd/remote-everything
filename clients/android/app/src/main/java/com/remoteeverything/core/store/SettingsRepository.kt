package com.remoteeverything.core.store

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.remoteeverything.core.model.Identity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

enum class Language { SYSTEM, ZH, EN }

enum class Appearance { SYSTEM, LIGHT, DARK }

data class Settings(
    val language: Language = Language.SYSTEM,
    val appearance: Appearance = Appearance.SYSTEM,
)

private val Context.settingsStore by preferencesDataStore(name = "settings")

/**
 * Local persistence: settings and the identity list. Nodes are never
 * persisted as truth — they are rebuilt from the wire on every refresh.
 */
class SettingsRepository(private val context: Context) {

    private object Keys {
        val LANGUAGE = stringPreferencesKey("language")
        val APPEARANCE = stringPreferencesKey("appearance")
        val IDENTITIES = stringPreferencesKey("identities")
    }

    private val json = Json { ignoreUnknownKeys = false }

    val settings: Flow<Settings> = context.settingsStore.data.map { prefs ->
        Settings(
            language = prefs[Keys.LANGUAGE]?.let { runCatching { Language.valueOf(it) }.getOrNull() }
                ?: Language.SYSTEM,
            appearance = prefs[Keys.APPEARANCE]?.let { runCatching { Appearance.valueOf(it) }.getOrNull() }
                ?: Appearance.SYSTEM,
        )
    }

    val identities: Flow<List<Identity>> = context.settingsStore.data.map { prefs ->
        prefs[Keys.IDENTITIES]?.let { raw ->
            runCatching { json.decodeFromString(ListSerializer(Identity.serializer()), raw) }.getOrNull()
        } ?: emptyList()
    }

    suspend fun setLanguage(language: Language) {
        context.settingsStore.edit { it[Keys.LANGUAGE] = language.name }
    }

    suspend fun setAppearance(appearance: Appearance) {
        context.settingsStore.edit { it[Keys.APPEARANCE] = appearance.name }
    }

    suspend fun saveIdentities(identities: List<Identity>) {
        context.settingsStore.edit {
            it[Keys.IDENTITIES] = json.encodeToString(ListSerializer(Identity.serializer()), identities)
        }
    }

    /** The identities as they are right now, for a caller that is not a screen. */
    suspend fun currentIdentities(): List<Identity> = identities.first()
}
