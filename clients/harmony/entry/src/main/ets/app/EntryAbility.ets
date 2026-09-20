// The ability: it hands the model everything it needs to exist, follows the app in
// and out of the foreground, and turns an invitation link into the add-node flow.
//
// It also hands the web kernel its download delegate, which is the one piece of the
// web host that has to be installed before any page exists.
//
// Orientation is deliberately not set here: the app declares none, every ordinary
// screen follows the system (ui-contract §6), and the only thing that holds the screen
// is an application's own panel — asked for by `app/web/WebScreen.ets` while that
// application is open and given back on the way out. A preferred orientation is also
// ignored in split screen and freeform windows, so this is a preference, not a lock.

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { model } from './AppModel';
import { BuildInfo } from './BuildInfo';
import { WebDownloads } from './web/WebDownloads';
import { HuksVault } from '../core/identity/HuksVault';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteEverything';

export default class EntryAbility extends UIAbility {
  /** The link this run has already opened the add-node flow with. */
  private openedLink: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.handleWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      // The kernel is initialised once, before the first Web component exists, so the
      // first application page does not pay for it.
      webview.WebviewController.initializeWebEngine();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'the web engine was already initialised');
    }
    // Downloads a page starts are answered by this delegate for the life of the app.
    WebDownloads.install(this.context);
    new HuksVault().selfTest().catch(() => {});
    model.setVersions(BuildInfo.versionName(), BuildInfo.buildNumber());
    model.boot(this.context).then(() => {
      windowStage.loadContent('pages/AppRoot').catch((error: Error) => {
        hilog.error(DOMAIN, TAG, `loadContent failed: ${error.message}`);
      });
    }).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, `boot failed: ${error.message}`);
      windowStage.loadContent('pages/AppRoot').catch(() => {
      });
    });
  }

  onForeground(): void {
    model.foregroundChanged(true);
  }

  onBackground(): void {
    model.foregroundChanged(false);
  }

  onConfigurationUpdate(configuration: Configuration): void {
    model.refreshSystemDark();
  }

  /** `remote-everything://setup?…` opens the add-node flow with the link filled in. */
  private handleWant(want: Want): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri === '') {
      return;
    }
    if (!uri.toLowerCase().startsWith('remote-everything://')) {
      return;
    }
    if (uri === this.openedLink) {
      // A want outlives its delivery: a recreated ability — a language switch is
      // one — is handed the same want again, and reopening the flow with it is how
      // the add-node screen used to appear on its own, filled in with the last
      // link. The link is consumed, so it leaves with its delivery.
      return;
    }
    this.openedLink = uri;
    model.openFromLink(uri);
  }
}
