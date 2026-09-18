// Every word the app says, looked up from the resource files by message key.
//
// The words live in `resources/base/element/string.json` (English, the default) and
// `resources/zh_CN/element/string.json`; this file holds no sentence, only the keys
// that name one (app/i18n/MessageKeys.ets). A key without a translation renders as
// the key itself, which is a bug and looks like one.

import { i18n } from '@kit.LocalizationKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppState, Appearance, Language } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';

export class Strings {
  private static manager: resourceManager.ResourceManager | null = null;
  private static language: Language = Language.System;

  /** Called once from the ability, before anything is drawn. */
  static attach(manager: resourceManager.ResourceManager, language: Language): void {
    Strings.manager = manager;
    Strings.language = language;
  }

  /**
   * Applies a language: the platform is told, so a cold start comes up in it, and the
   * running process is told as well, which is what makes the switch immediate
   * (ui-contract §5).
   */
  static apply(context: common.UIAbilityContext, language: Language): void {
    Strings.language = language;
    try {
      if (language === Language.System) {
        i18n.System.setAppPreferredLanguage('default');
        context.getApplicationContext().setLanguage(i18n.System.getSystemLanguage());
      } else {
        const tag: string = language === Language.Chinese ? 'zh-Hans' : 'en';
        i18n.System.setAppPreferredLanguage(tag);
        context.getApplicationContext().setLanguage(tag);
      }
    } catch (error) {
      // The setting is remembered either way; a platform that refuses the immediate
      // switch picks the language up on the next start.
    }
  }

  /** One message, by its contract key. */
  static text(key: string): string {
    return Strings.byName(MessageKeys.resource(key));
  }

  /** One message with one substitution. */
  static text1(key: string, first: string): string {
    return Strings.byName1(MessageKeys.resource(key), first);
  }

  /** One message with two substitutions. */
  static text2(key: string, first: string, second: string): string {
    return Strings.byName2(MessageKeys.resource(key), first, second);
  }

  /** A resource that is not a message: the app's own name, a permission's reason. */
  static byName(name: string): string {
    const manager: resourceManager.ResourceManager | null = Strings.manager;
    if (manager === null) {
      return name;
    }
    try {
      return manager.getStringByNameSync(name);
    } catch (error) {
      return name;
    }
  }

  private static byName1(name: string, first: string): string {
    const manager: resourceManager.ResourceManager | null = Strings.manager;
    if (manager === null) {
      return name;
    }
    try {
      return manager.getStringByNameSync(name, first);
    } catch (error) {
      return name;
    }
  }

  private static byName2(name: string, first: string, second: string): string {
    const manager: resourceManager.ResourceManager | null = Strings.manager;
    if (manager === null) {
      return name;
    }
    try {
      return manager.getStringByNameSync(name, first, second);
    } catch (error) {
      return name;
    }
  }

  /** The words for an app's state, by its code. */
  static appState(state: AppState): string {
    return Strings.text(MessageKeys.forAppState(state));
  }
}

/** The name this device suggests for itself, before its operator renames it. */
export function defaultDeviceName(): string {
  // HarmonyOS does not let an app read the name of the OS account it runs under, so
  // the platform default here is the device's own category — the second half of the
  // "<user>'s <kind of device>" an operator would otherwise see.
  return Strings.byName(deviceCategoryResource());
}

export function deviceCategoryResource(): string {
  let type: string = '';
  try {
    type = deviceInfo.deviceType;
  } catch (error) {
    type = '';
  }
  if (type === 'phone') {
    return 'device_category_phone';
  }
  if (type === 'tablet') {
    return 'device_category_tablet';
  }
  return 'device_category_default';
}
