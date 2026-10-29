package com.remoteeverything.app.i18n

import android.content.Context
import android.content.res.Resources
import android.os.LocaleList
import android.view.ContextThemeWrapper
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
        return wrap(base, language)
    }

    fun wrap(base: Context, language: Language): Context {
        val locales = when (language) {
            Language.SYSTEM -> Resources.getSystem().configuration.locales
            Language.ZH -> LocaleList(Locale.forLanguageTag("zh"))
            Language.EN -> LocaleList(Locale.forLanguageTag("en"))
        }
        // Override only locale fields so size, orientation and system appearance
        // continue to follow configuration changes without recreating the Activity.
        val config = android.content.res.Configuration()
        config.setLocales(locales)
        config.setLayoutDirection(locales[0])
        // Keep the host Activity in the wrapper chain for result/permission launchers.
        return ContextThemeWrapper(base, 0).apply { applyOverrideConfiguration(config) }
    }
}
