package com.remoteeverything.app

import android.content.Context
import com.remoteeverything.core.store.Language
import java.util.Locale

/**
 * In-app language override. The DataStore is async and unreadable during
 * attachBaseContext, so the override is mirrored to a plain SharedPreferences
 * file that is synchronously readable when the activity context is created.
 */
object LocaleHelper {

    private const val PREFS = "locale_override"
    private const val KEY = "language"

    fun persistOverride(context: Context, language: Language) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, language.name)
            .apply()
    }

    fun wrap(base: Context): Context {
        val language = base.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null)
            ?.let { runCatching { Language.valueOf(it) }.getOrNull() }
            ?: Language.SYSTEM
        val tag = when (language) {
            Language.SYSTEM -> return base
            Language.ZH -> "zh"
            Language.EN -> "en"
        }
        val locale = Locale.forLanguageTag(tag)
        val config = android.content.res.Configuration(base.resources.configuration)
        config.setLocale(locale)
        config.setLayoutDirection(locale)
        return base.createConfigurationContext(config)
    }
}
