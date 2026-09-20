// Window size measurement and dark mode resolution for HarmonyOS.

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { Appearance } from '../core/model/Models';
import { WebOrientation } from '../core/store/WebAppPrefs';

export const WIDE_WIDTH_VP = 840;

export class WindowLayout {
  /**
   * Watches the window: a window width of 840 vp or more is a screen with room for two
   * columns, and a foldable unfolding is a size change rather than a new screen. The
   * short side still drives the UI scale, and it is measured synchronously first — the
   * first frame must already come out at the right size.
   */
  static listenWindowSize(context: Context | undefined, onWideChange: (wide: boolean, shortSideVp: number) => void): void {
    if (context === undefined) {
      return;
    }
    const report = (widthPx: number, heightPx: number, density: number): void => {
      if (density <= 0) {
        return;
      }
      onWideChange(widthPx / density >= WIDE_WIDTH_VP,
        Math.min(widthPx, heightPx) / density);
    };
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      report(screen.width, screen.height, screen.densityPixels);
    } catch (error) {
      // The window measure below answers when the display cannot.
    }
    const measure = (size: window.Size): void => {
      try {
        const density: number = display.getDefaultDisplaySync().densityPixels;
        report(size.width, size.height, density);
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
        // The synchronous measure above stands.
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

  /**
   * The web host's screen, and the only screen that leaves the app's own chrome
   * behind: a page is shown with no system bars over it, and the bars come back when
   * the host is left. Everything else in the app keeps them.
   */
  static applyFullscreen(context: Context | undefined, enabled: boolean): void {
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((host: window.Window) => {
      try {
        host.setWindowLayoutFullScreen(enabled);
      } catch (error) {
        // A window that refuses the layout keeps the bars it has.
      }
      try {
        host.setWindowSystemBarEnable(enabled ? [] : ['status', 'navigation']);
      } catch (error) {
        // Same: the layout is worth having even if a bar stays.
      }
    }).catch(() => {
      // No window to ask.
    });
  }

  /**
   * An application's own choice of orientation, and only while it is open: the host
   * asks for it on the way in and gives the screen back to the system on the way out
   * (ui-contract §6, revised). Nothing else in the app locks an orientation.
   */
  static applyOrientation(context: Context | undefined, orientation: WebOrientation): void {
    if (context === undefined) {
      return;
    }
    const wanted: window.Orientation = orientation === WebOrientation.Portrait
      ? window.Orientation.PORTRAIT
      : orientation === WebOrientation.Landscape
        ? window.Orientation.LANDSCAPE
        : window.Orientation.UNSPECIFIED;
    window.getLastWindow(context).then((host: window.Window) => {
      try {
        host.setPreferredOrientation(wanted);
      } catch (error) {
        // Split screen and freeform windows ignore a preference: nothing to do.
      }
    }).catch(() => {
      // No window to ask.
    });
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
