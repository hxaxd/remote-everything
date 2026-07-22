import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

export class ClientSettings {
  private static readonly STORE_NAME = 'RemoteEverything';
  private static store: preferences.Preferences | null = null;

  static init(context: common.UIAbilityContext): void {
    try {
      ClientSettings.store = preferences.getPreferencesSync(context, { name: ClientSettings.STORE_NAME });
    } catch {
      throw new Error('客户端设置初始化失败');
    }
  }

  static globalOrientation(): string {
    return ClientSettings.value('global_orientation', ['system', 'portrait', 'landscape'], 'system');
  }

  static setGlobalOrientation(value: string): void {
    ClientSettings.put('global_orientation', ClientSettings.validated(
      value, ['system', 'portrait', 'landscape'], 'system'
    ));
  }

  static globalDisplayMode(): string {
    return ClientSettings.value('global_display_mode', ['phone', 'desktop'], 'phone');
  }

  static setGlobalDisplayMode(value: string): void {
    ClientSettings.put('global_display_mode', ClientSettings.validated(
      value, ['phone', 'desktop'], 'phone'
    ));
  }

  static themeMode(): string {
    return ClientSettings.value('theme_mode', ['system', 'light', 'dark'], 'system');
  }

  static setThemeMode(value: string): void {
    ClientSettings.put('theme_mode', ClientSettings.validated(
      value, ['system', 'light', 'dark'], 'system'
    ));
  }

  static appOrientation(installationId: string, appId: string): string {
    return ClientSettings.value(
      ClientSettings.appKey('orientation', installationId, appId),
      ['global', 'system', 'portrait', 'landscape'],
      'global'
    );
  }

  static setAppOrientation(installationId: string, appId: string, value: string): void {
    ClientSettings.put(
      ClientSettings.appKey('orientation', installationId, appId),
      ClientSettings.validated(value, ['global', 'system', 'portrait', 'landscape'], 'global')
    );
  }

  static resolveOrientation(installationId: string, appId: string): string {
    const value = ClientSettings.appOrientation(installationId, appId);
    return value === 'global' ? ClientSettings.globalOrientation() : value;
  }

  static appDisplayMode(installationId: string, appId: string): string {
    return ClientSettings.value(
      ClientSettings.appKey('display', installationId, appId),
      ['global', 'phone', 'desktop'],
      'global'
    );
  }

  static setAppDisplayMode(installationId: string, appId: string, value: string): void {
    ClientSettings.put(
      ClientSettings.appKey('display', installationId, appId),
      ClientSettings.validated(value, ['global', 'phone', 'desktop'], 'global')
    );
  }

  static resolveDisplayMode(installationId: string, appId: string): string {
    const value = ClientSettings.appDisplayMode(installationId, appId);
    return value === 'global' ? ClientSettings.globalDisplayMode() : value;
  }

  static removeInstallation(installationId: string): void {
    const store = ClientSettings.requireStore();
    const marker = `_${installationId}_`;
    try {
      const values = store.getAllSync();
      Object.keys(values).forEach((key: string) => {
        if ((key.startsWith('orientation_') || key.startsWith('display_')) && key.includes(marker)) {
          store.deleteSync(key);
        }
      });
      ClientSettings.flush(store);
    } catch {
      // Profile removal remains valid even if non-secret presentation settings cannot be cleaned.
    }
  }

  static applyTheme(context: common.UIAbilityContext, value: string = ClientSettings.themeMode()): void {
    const mode = value === 'dark'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : value === 'light'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      context.getApplicationContext().setColorMode(mode);
    } catch {
      // Keep the current system appearance when the host context cannot change it.
    }
  }

  static async applyOrientation(
    context: common.UIAbilityContext,
    value: string = ClientSettings.globalOrientation()
  ): Promise<void> {
    const orientation = value === 'portrait'
      ? window.Orientation.PORTRAIT
      : value === 'landscape'
        ? window.Orientation.AUTO_ROTATION_LANDSCAPE
        : window.Orientation.AUTO_ROTATION_RESTRICTED;
    try {
      const mainWindow = await window.getLastWindow(context);
      await mainWindow.setPreferredOrientation(orientation);
    } catch {
      // Rotation can be unavailable on fixed-orientation and multi-window devices.
    }
  }

  private static appKey(prefix: string, installationId: string, appId: string): string {
    return `${prefix}_${installationId}_${appId}`;
  }

  private static value(key: string, allowed: string[], fallback: string): string {
    try {
      const stored = ClientSettings.requireStore().getSync(key, fallback) as string;
      return allowed.length === 0 ? stored : ClientSettings.validated(stored, allowed, fallback);
    } catch {
      return fallback;
    }
  }

  private static validated(value: string, allowed: string[], fallback: string): string {
    return allowed.includes(value) ? value : fallback;
  }

  private static put(key: string, value: string): void {
    const store = ClientSettings.requireStore();
    try {
      store.putSync(key, value);
      ClientSettings.flush(store);
    } catch {
      // The current UI value remains valid; the next mutation can retry persistence.
    }
  }

  private static flush(store: preferences.Preferences): void {
    store.flush().catch(() => {
      // The in-memory value remains available; a later mutation retries persistence.
    });
  }

  private static requireStore(): preferences.Preferences {
    if (ClientSettings.store === null) {
      throw new Error('客户端设置尚未初始化');
    }
    return ClientSettings.store;
  }
}
