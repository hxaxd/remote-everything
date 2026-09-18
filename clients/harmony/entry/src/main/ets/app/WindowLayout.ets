// Window size measurement and dark mode resolution for HarmonyOS.

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { Appearance } from '../core/model/Models';

export const WIDE_SHORT_SIDE_VP = 840;

export class WindowLayout {
  /**
   * Watches the window: a short side of 840 vp or more is a screen with room for two
   * columns, and a foldable unfolding is a size change rather than a new screen.
   */
  static listenWindowSize(context: Context | undefined, onWideChange: (wide: boolean) => void): void {
    if (context === undefined) {
      return;
    }
    const measure = (size: window.Size): void => {
      try {
        const density: number = display.getDefaultDisplaySync().densityPixels;
        if (density <= 0) {
          return;
        }
        const shortSide: number = Math.min(size.width, size.height) / density;
        onWideChange(shortSide >= WIDE_SHORT_SIDE_VP);
      } catch (error) {
        // Leave layout as is
      }
    };
    let pending: Promise<window.Window>;
    try {
      pending = window.getLastWindow(context);
    } catch (error) {
      return;
    }
    pending.then((host: window.Window) => {
      try {
        host.on('windowSizeChange', measure);
      } catch (error) {
        // Fallback to initial
      }
      try {
        const rect: window.Rect = host.getWindowProperties().windowRect;
        measure({ width: rect.width, height: rect.height });
      } catch (error) {
        // Fallback
      }
    }).catch(() => {
      // Ignore
    });
  }

  static readSystemDark(context: common.UIAbilityContext): boolean {
    try {
      return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      return false;
    }
  }

  static effectiveDark(appearance: Appearance, systemDark: boolean): boolean {
    if (appearance === Appearance.Dark) {
      return true;
    }
    if (appearance === Appearance.Light) {
      return false;
    }
    return systemDark;
  }

  static applyColorMode(context: common.UIAbilityContext, appearance: Appearance): void {
    try {
      const mode: ConfigurationConstant.ColorMode = appearance === Appearance.Dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : appearance === Appearance.Light
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      context.getApplicationContext().setColorMode(mode);
    } catch (error) {
      // Ignore
    }
  }
}
