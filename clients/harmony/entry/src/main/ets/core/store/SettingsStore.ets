// The two settings that outlive a session: the language and the appearance. They
// are read before the first frame and written the moment they change, and an
// unreadable store is a store with the defaults in it, never a crash.

import { preferences } from '@kit.ArkData';
import { Appearance, Language } from '../model/Models';

const STORE_NAME = 'settings';
const KEY_LANGUAGE = 'language';
const KEY_APPEARANCE = 'appearance';

export class Settings {
  readonly language: Language;
  readonly appearance: Appearance;

  constructor(language: Language, appearance: Appearance) {
    this.language = language;
    this.appearance = appearance;
  }

  static defaults(): Settings {
    return new Settings(Language.System, Appearance.System);
  }

  withLanguage(language: Language): Settings {
    return new Settings(language, this.appearance);
  }

  withAppearance(appearance: Appearance): Settings {
    return new Settings(this.language, appearance);
  }
}

function readLanguage(value: string | null): Language {
  if (value === Language.Chinese) {
    return Language.Chinese;
  }
  if (value === Language.English) {
    return Language.English;
  }
  return Language.System;
}

function readAppearance(value: string | null): Appearance {
  if (value === Appearance.Light) {
    return Appearance.Light;
  }
  if (value === Appearance.Dark) {
    return Appearance.Dark;
  }
  return Appearance.System;
}

export class SettingsStore {
  private store: preferences.Preferences | null = null;

  open(context: Context): Settings {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (error) {
      this.store = null;
      return Settings.defaults();
    }
    return this.read();
  }

  read(): Settings {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return Settings.defaults();
    }
    try {
      const language: string = store.getSync(KEY_LANGUAGE, '') as string;
      const appearance: string = store.getSync(KEY_APPEARANCE, '') as string;
      return new Settings(readLanguage(language), readAppearance(appearance));
    } catch (error) {
      // A store that cannot be read is a store with the defaults in it.
      return Settings.defaults();
    }
  }

  write(settings: Settings): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_LANGUAGE, settings.language);
      this.store.putSync(KEY_APPEARANCE, settings.appearance);
      this.store.flushSync();
    } catch (error) {
      // A setting that could not be written is a setting for this run only; the app
      // stays usable and the next change tries again.
    }
  }
}
