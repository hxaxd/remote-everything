// The ability: it hands the model everything it needs to exist, follows the app in
// and out of the foreground, and turns an invitation link into the add-node flow.
//
// There is deliberately no orientation to set: every screen follows the system
// (ui-contract §6), and the platform documents that a preferred orientation is ignored
// in split screen and freeform windows anyway — so asking for one would be asking for
// nothing (pitfalls §5).

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { model } from './AppModel';
import { BuildInfo } from './BuildInfo';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteEverything';

export default class EntryAbility extends UIAbility {
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
    model.openFromLink(uri);
  }
}
